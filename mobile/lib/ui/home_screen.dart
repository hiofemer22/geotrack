import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../config.dart';
import '../data/local_db.dart';
import '../services/telemetry.dart';
import '../services/tracking_service.dart';
import 'history_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _map = MapController();
  final _route = <LatLng>[];
  LatLng? _me;
  double? _heading;
  bool _tracking = false;
  bool _busy = false;
  bool _follow = true;
  int? _startedAt;
  Map<String, dynamic> _t = {};
  StreamSubscription? _updatesSub;
  StreamSubscription<Position>? _uiPosSub;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _updatesSub = TrackingService.updates.listen(_onUpdate);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_tracking && mounted) setState(() {});
    });
    _restore();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _updatesSub?.cancel();
    _uiPosSub?.cancel();
    _clock?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Al volver a la app se recarga la ruta desde SQLite (el servicio siguió grabando).
    if (state == AppLifecycleState.resumed) _restore();
  }

  Future<void> _restore() async {
    final running = await TrackingService.isRunning();
    final cfg = await AppConfig.load();
    final id = cfg.activeSessionId;
    if (running && id != null) {
      final db = await LocalDb.open();
      final s = await db.getSession(id);
      final pts = await db.pointsFor(id);
      if (!mounted) return;
      setState(() {
        _tracking = true;
        _startedAt = s?.startedAt;
        _route
          ..clear()
          ..addAll(pts.map((p) => LatLng(p.lat, p.lng)));
        if (pts.isNotEmpty) _me = _route.last;
        _t = {
          ..._t,
          'distance': s?.distance ?? 0,
          'calories': s?.calories ?? 0,
          'activity': pts.isNotEmpty ? pts.last.activity : null,
        };
      });
    } else {
      if (mounted) setState(() => _tracking = false);
      _watchUiPosition();
    }
  }

  /// Punto azul cuando no se está rastreando (solo con la app abierta).
  Future<void> _watchUiPosition() async {
    if (_uiPosSub != null) return;
    final perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;
    _uiPosSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((p) {
      if (_tracking || !mounted) return;
      final first = _me == null;
      setState(() {
        _me = LatLng(p.latitude, p.longitude);
        _heading = p.heading;
      });
      if (first || _follow) _map.move(_me!, first ? 17 : _map.camera.zoom);
    });
  }

  void _onUpdate(Map<String, dynamic>? data) {
    if (data == null || !mounted) return;
    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    setState(() {
      _t = data;
      _tracking = true;
      if (lat != null && lng != null) {
        final p = LatLng(lat, lng);
        if (_route.isEmpty || _route.last != p) _route.add(p);
        _me = p;
        _heading = (data['heading'] as num?)?.toDouble();
      }
    });
    if (_follow && _me != null) _map.move(_me!, _map.camera.zoom);
  }

  Future<void> _toggle() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_tracking) {
        await TrackingService.stop();
        setState(() {
          _tracking = false;
          _t = {};
        });
        _showSnack('Rastreo detenido. La sesión quedó guardada en el historial.');
      } else {
        final error = await TrackingService.ensurePermissions();
        if (error != null) {
          _showSnack(error);
          return;
        }
        await TrackingService.start();
        setState(() {
          _tracking = true;
          _route.clear();
          _startedAt = DateTime.now().millisecondsSinceEpoch;
          _t = {};
          _follow = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sos() async {
    await TrackingService.sendSos(_me?.latitude, _me?.longitude);
    _showSnack('🚨 Alerta SOS enviada al centro de monitoreo', color: Palette.danger);
  }

  void _showSnack(String msg, {Color? color}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final activity = Activity.fromName(_t['activity'] as String?);
    final pending = (_t['pending'] as int?) ?? 0;
    final online = _t['online'] as bool?;

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _me ?? const LatLng(19.4326, -99.1332),
              initialZoom: 15,
              onPositionChanged: (_, hasGesture) {
                if (hasGesture && _follow) setState(() => _follow = false);
              },
            ),
            children: [
              baseTiles(),
              if (_route.length > 1)
                PolylineLayer(polylines: [
                  Polyline(points: _route, strokeWidth: 9, color: Colors.white),
                  Polyline(points: _route, strokeWidth: 5.5, color: Palette.primary),
                ]),
              if (_me != null)
                MarkerLayer(markers: [
                  Marker(point: _me!, width: 44, height: 44, child: MyLocationDot(heading: _heading, active: _tracking)),
                ]),
            ],
          ),

          // Barra superior flotante
          Positioned(
            top: pad.top + 12,
            left: 16,
            right: 16,
            child: FloatingCard(
              radius: 28,
              padding: const EdgeInsets.fromLTRB(20, 6, 6, 6),
              child: Row(
                children: [
                  const Icon(Icons.my_location, color: Palette.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('GeoTrack', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                        StatusLine(tracking: _tracking, online: online, pending: pending),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Historial',
                    icon: const Icon(Icons.history, color: Palette.muted),
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen())),
                  ),
                  IconButton(
                    tooltip: 'Ajustes',
                    icon: const Icon(Icons.settings_outlined, color: Palette.muted),
                    onPressed: () async {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
                    },
                  ),
                ],
              ),
            ),
          ),

          // Botones flotantes laterales
          Positioned(
            right: 16,
            bottom: (_tracking ? 220 : 120) + pad.bottom,
            child: Column(
              children: [
                SosButton(onTriggered: _sos),
                const SizedBox(height: 12),
                RoundFab(
                  icon: _follow ? Icons.my_location : Icons.location_searching,
                  color: _follow ? Palette.primary : Palette.muted,
                  onPressed: () {
                    setState(() => _follow = true);
                    if (_me != null) _map.move(_me!, 17);
                  },
                ),
              ],
            ),
          ),

          // Panel de telemetría + botón Iniciar/Detener
          Positioned(
            left: 16,
            right: 16,
            bottom: pad.bottom + 20,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  child: _tracking
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TelemetryCard(
                            speedMps: (_t['speed'] as num?)?.toDouble() ?? 0,
                            distanceM: (_t['distance'] as num?)?.toDouble() ?? 0,
                            calories: (_t['calories'] as num?)?.toDouble() ?? 0,
                            elapsed: _startedAt == null
                                ? Duration.zero
                                : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(_startedAt!)),
                            activity: activity,
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Center(child: TrackButton(tracking: _tracking, busy: _busy, onPressed: _toggle)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
