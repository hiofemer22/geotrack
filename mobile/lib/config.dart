import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Configuración persistente compartida entre la UI y el servicio en segundo plano.
class AppConfig {
  static const _kServer = 'server_url';
  static const _kApiKey = 'api_key';
  static const _kDeviceId = 'device_id';
  static const _kDeviceName = 'device_name';
  static const _kWeight = 'weight_kg';
  static const _kInterval = 'interval_sec';
  static const _kActiveSession = 'active_session';

  // Valores por defecto: se inyectan al compilar (--dart-define) y se cambian desde Ajustes.
  static const defaultServer =
      String.fromEnvironment('SERVER_URL', defaultValue: 'http://10.228.181.57:8080'); // IP de tu PC en la red Wi-Fi
  static const defaultApiKey = String.fromEnvironment('DEVICE_API_KEY', defaultValue: 'dev-device-key');

  final SharedPreferences _p;
  AppConfig._(this._p);

  static Future<AppConfig> load() async {
    final p = await SharedPreferences.getInstance();
    await p.reload(); // el otro isolate pudo haber escrito cambios
    final cfg = AppConfig._(p);
    if (p.getString(_kDeviceId) == null) {
      await p.setString(_kDeviceId, const Uuid().v4());
    }
    return cfg;
  }

  String get serverUrl => _p.getString(_kServer) ?? defaultServer;
  String get apiKey => _p.getString(_kApiKey) ?? defaultApiKey;
  String get deviceId => _p.getString(_kDeviceId)!;
  String get deviceName => _p.getString(_kDeviceName) ?? 'Mi teléfono';
  double get weightKg => _p.getDouble(_kWeight) ?? 70;
  int get intervalSec => _p.getInt(_kInterval) ?? 5;
  String? get activeSessionId => _p.getString(_kActiveSession);

  Future<void> save({
    String? serverUrl,
    String? apiKey,
    String? deviceName,
    double? weightKg,
    int? intervalSec,
  }) async {
    if (serverUrl != null) await _p.setString(_kServer, serverUrl.trim().replaceAll(RegExp(r'/+$'), ''));
    if (apiKey != null) await _p.setString(_kApiKey, apiKey.trim());
    if (deviceName != null) await _p.setString(_kDeviceName, deviceName.trim());
    if (weightKg != null) await _p.setDouble(_kWeight, weightKg);
    if (intervalSec != null) await _p.setInt(_kInterval, intervalSec.clamp(5, 10));
  }

  Future<void> setActiveSession(String? id) async {
    if (id == null) {
      await _p.remove(_kActiveSession);
    } else {
      await _p.setString(_kActiveSession, id);
    }
  }
}
