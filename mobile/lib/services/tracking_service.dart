import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../config.dart';
import '../data/local_db.dart';
import '../data/models.dart';
import 'location_filter.dart';
import 'sync_service.dart';
import 'telemetry.dart';

const _channelId = 'geotrack_tracking';
const _notificationId = 888;

/// API usada por la interfaz para controlar el servicio.
class TrackingService {
  static final _service = FlutterBackgroundService();

  static Future<void> initialize() async {
    final notifications = FlutterLocalNotificationsPlugin();
    await notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          'Rastreo de ubicación',
          description: 'Notificación persistente mientras el rastreo está activo',
          importance: Importance.low,
        ));

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onServiceStart,
        autoStart: false,
        autoStartOnBoot: true, // si el teléfono se reinicia con una sesión activa, se reanuda
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'GeoTrack',
        initialNotificationContent: 'Iniciando rastreo…',
        foregroundServiceNotificationId: _notificationId,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(autoStart: false, onForeground: onServiceStart),
    );
  }

  /// Pide los permisos necesarios. Devuelve null si todo está bien o un mensaje de error.
  static Future<String?> ensurePermissions() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
      return 'Activa la ubicación (GPS) del teléfono.';
    }
    if (!(await Permission.location.request()).isGranted) {
      return 'Se necesita permiso de ubicación.';
    }
    await Permission.notification.request();
    // Android 10+: el permiso "Permitir todo el tiempo" se pide aparte (abre Ajustes).
    if (!(await Permission.locationAlways.isGranted)) {
      final s = await Permission.locationAlways.request();
      if (!s.isGranted) {
        return 'Para rastrear con la pantalla bloqueada elige "Permitir todo el tiempo" en el permiso de ubicación.';
      }
    }
    // Evita que el ahorro de batería de Android (y capas como MIUI/One UI) mate el servicio.
    if (!(await Permission.ignoreBatteryOptimizations.isGranted)) {
      await Permission.ignoreBatteryOptimizations.request();
    }
    return null;
  }

  static Future<bool> isRunning() => _service.isRunning();

  static Future<String> start() async {
    final cfg = await AppConfig.load();
    final db = await LocalDb.open();
    final id = const Uuid().v4();
    final now = DateTime.now();
    await db.insertSession(Session(id: id, startedAt: now.millisecondsSinceEpoch));
    await db.enqueue('POST', '/api/sessions/start', {
      'deviceId': cfg.deviceId,
      'sessionId': id,
      'startedAt': now.toUtc().toIso8601String(),
    });
    await cfg.setActiveSession(id);
    await _service.startService();
    return id;
  }

  static Future<void> stop() async {
    if (await _service.isRunning()) {
      _service.invoke('stop');
    } else {
      // El servicio no está corriendo (p.ej. fue detenido por el sistema): cerrar la sesión aquí.
      await _finishSession(await AppConfig.load(), await LocalDb.open());
    }
  }

  static Future<void> sendSos(double? lat, double? lng) async {
    if (await _service.isRunning()) {
      _service.invoke('sos', {'lat': lat, 'lng': lng});
      return;
    }
    final cfg = await AppConfig.load();
    final db = await LocalDb.open();
    await db.enqueue('POST', '/api/alerts/sos', {'deviceId': cfg.deviceId, 'lat': lat, 'lng': lng});
    await SyncService(db).flush();
  }

  static Future<void> renameSession(String id, String name) async {
    final db = await LocalDb.open();
    await db.renameSession(id, name);
    await db.enqueue('PATCH', '/api/sessions/$id', {'name': name});
    unawaited(SyncService(db).flush());
  }

  static Stream<Map<String, dynamic>?> get updates => _service.on('update');
}

Future<void> _finishSession(AppConfig cfg, LocalDb db) async {
  final id = cfg.activeSessionId;
  if (id == null) return;
  final s = await db.getSession(id);
  final end = DateTime.now();
  await db.endSession(id, end.millisecondsSinceEpoch);
  await db.enqueue('POST', '/api/sessions/$id/stop', {
    'deviceId': cfg.deviceId,
    'endedAt': end.toUtc().toIso8601String(),
    'distance': s?.distance ?? 0,
    'calories': s?.calories ?? 0,
  });
  await cfg.setActiveSession(null);
}

// ============================================================================
// Código que corre DENTRO del servicio en primer plano (isolate independiente).
// Sigue vivo aunque la app se cierre desde "recientes" o la pantalla se bloquee.
// ============================================================================
@pragma('vm:entry-point')
Future<void> onServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  final cfg = await AppConfig.load();
  final db = await LocalDb.open();
  final sync = SyncService(db);
  final battery = Battery();

  final sessionId = cfg.activeSessionId;
  if (sessionId == null) {
    // Arranque automático tras reinicio sin sesión activa: nada que hacer.
    await service.stopSelf();
    return;
  }

  final session = await db.getSession(sessionId);
  final telemetry = TelemetryCalculator(
    weightKg: cfg.weightKg,
    distance: session?.distance ?? 0,
    calories: session?.calories ?? 0,
    maxSpeed: session?.maxSpeed ?? 0,
  );
  final last = await db.lastPoint(sessionId);
  if (last != null) telemetry.restoreLast(last.lat, last.lng, last.ts);

  int? batteryLevel;
  Position? lastPosition;
  final filter = LocationFilter();
  FilteredFix? lastFiltered;
  StreamSubscription<Position>? sub;
  Timer? syncTimer;
  Timer? watchdog;
  var stopping = false;

  Future<void> readBattery() async {
    try {
      batteryLevel = await battery.batteryLevel;
    } catch (_) {}
  }

  await readBattery();

  Future<void> publish() async {
    final pending = await db.pendingCount();
    final kmh = (telemetry.speed * 3.6).toStringAsFixed(1);
    final km = (telemetry.distance / 1000).toStringAsFixed(2);
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Rastreo activo · ${telemetry.activity.label}',
        content: '$kmh km/h · $km km · ${telemetry.calories.toStringAsFixed(0)} kcal'
            '${pending > 0 ? ' · $pending en cola' : ''}',
      );
    }
    service.invoke('update', {
      'sessionId': sessionId,
      'lat': lastFiltered?.lat,
      'lng': lastFiltered?.lng,
      'accuracy': lastPosition?.accuracy,
      'heading': lastPosition?.heading,
      'ts': lastPosition?.timestamp.millisecondsSinceEpoch,
      'speed': telemetry.speed,
      'distance': telemetry.distance,
      'calories': telemetry.calories,
      'maxSpeed': telemetry.maxSpeed,
      'activity': telemetry.activity.name,
      'pending': pending,
      'online': sync.online,
      'battery': batteryLevel,
    });
  }

  DateTime lastFix = DateTime.now();

  Future<void> onPosition(Position pos) async {
    lastFix = DateTime.now();
    final ts = pos.timestamp.millisecondsSinceEpoch;
    final fix = filter.add(
      lat: pos.latitude, lng: pos.longitude, accuracy: pos.accuracy, ts: ts, speed: pos.speed, heading: pos.heading);
    if (fix == null) return; // lectura imprecisa o salto imposible: se descarta
    lastPosition = pos;
    lastFiltered = fix;
    telemetry.add(lat: fix.lat, lng: fix.lng, ts: ts, gpsSpeed: pos.speed, accuracy: pos.accuracy);
    await db.insertPoint(TrackPoint(
      sessionId: sessionId,
      ts: ts,
      lat: fix.lat,
      lng: fix.lng,
      speed: telemetry.speed,
      accuracy: pos.accuracy,
      heading: pos.heading,
      altitude: pos.altitude,
      battery: batteryLevel,
      activity: telemetry.activity.name,
    ));
    await db.updateSessionTotals(sessionId,
        distance: telemetry.distance, calories: telemetry.calories, maxSpeed: telemetry.maxSpeed);
    await publish();
  }

  void listen() {
    sub?.cancel();
    sub = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        intervalDuration: Duration(seconds: cfg.intervalSec),
      ),
    ).listen(onPosition, onError: (_) {});
  }

  listen();

  // Envío al servidor: cada intervalo se intenta vaciar la cola.
  syncTimer = Timer.periodic(Duration(seconds: cfg.intervalSec), (_) async {
    final wasOnline = sync.online;
    final hadPending = await db.pendingCount() > 0;
    await sync.flush();
    // Refrescar la pantalla aunque no llegue una posición nueva (p. ej. bajo techo, lecturas descartadas)
    if (sync.online != wasOnline || hadPending) await publish();
  });

  // Si el stream deja de entregar posiciones (algunos fabricantes lo pausan), se fuerza una lectura.
  watchdog = Timer.periodic(const Duration(seconds: 30), (_) async {
    await readBattery();
    if (DateTime.now().difference(lastFix).inSeconds > max(cfg.intervalSec * 4, 20)) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: AndroidSettings(accuracy: LocationAccuracy.high, timeLimit: const Duration(seconds: 15)),
        );
        await onPosition(pos);
      } catch (_) {}
      listen();
    }
  });

  service.on('sos').listen((data) async {
    final lat = (data?['lat'] as num?)?.toDouble() ?? lastFiltered?.lat;
    final lng = (data?['lng'] as num?)?.toDouble() ?? lastFiltered?.lng;
    await db.enqueue('POST', '/api/alerts/sos', {'deviceId': cfg.deviceId, 'lat': lat, 'lng': lng});
    await sync.flush();
  });

  service.on('stop').listen((_) async {
    if (stopping) return;
    stopping = true;
    await sub?.cancel();
    syncTimer?.cancel();
    watchdog?.cancel();
    await _finishSession(cfg, db);
    await sync.flush();
    service.invoke('stopped');
    await service.stopSelf();
  });

  await publish();
  await sync.flush();
}
