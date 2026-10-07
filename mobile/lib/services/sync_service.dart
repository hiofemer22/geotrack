import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../data/local_db.dart';

/// Envía al servidor todo lo que está en la cola local. Si no hay red, no pasa
/// nada: los datos siguen en SQLite y se reintenta en el siguiente ciclo.
class SyncService {
  SyncService(this.db);
  final LocalDb db;
  bool _running = false;
  bool _registered = false;
  DateTime? lastSuccess;
  bool online = false;

  Map<String, String> _headers(AppConfig cfg) => {'Content-Type': 'application/json', 'x-api-key': cfg.apiKey};

  Future<http.Response> _send(AppConfig cfg, String method, String path, Object body) {
    final uri = Uri.parse('${cfg.serverUrl}$path');
    final payload = jsonEncode(body);
    final req = switch (method) {
      'PATCH' => http.patch(uri, headers: _headers(cfg), body: payload),
      _ => http.post(uri, headers: _headers(cfg), body: payload),
    };
    return req.timeout(const Duration(seconds: 15));
  }

  Future<void> register(AppConfig cfg) async {
    final res = await _send(cfg, 'POST', '/api/devices/register',
        {'id': cfg.deviceId, 'name': cfg.deviceName, 'platform': 'android'});
    if (res.statusCode >= 300) throw Exception('registro falló: ${res.statusCode} ${res.body}');
    _registered = true;
  }

  /// Devuelve true si la cola quedó vacía.
  Future<bool> flush() async {
    if (_running) return false;
    _running = true;
    try {
      final cfg = await AppConfig.load();
      if (!_registered) await register(cfg);

      // 1) Puntos, en lotes de 500 (idempotente en el servidor)
      while (true) {
        final batch = await db.unsyncedPoints();
        if (batch.isEmpty) break;
        final bySession = <String, List<Map<String, Object?>>>{};
        for (final p in batch) {
          bySession.putIfAbsent(p.sessionId, () => []).add(p.toJson());
        }
        for (final entry in bySession.entries) {
          final res = await _send(cfg, 'POST', '/api/locations',
              {'deviceId': cfg.deviceId, 'sessionId': entry.key, 'points': entry.value});
          if (res.statusCode == 404) {
            _registered = false; // el servidor no conoce el dispositivo (p.ej. BD nueva)
            await register(cfg);
            return false;
          }
          if (res.statusCode >= 300) throw Exception('locations ${res.statusCode}');
        }
        await db.markSynced(batch.map((p) => p.id!).toList());
      }

      // 2) Operaciones (inicio/fin/renombrar sesión, SOS) en orden de creación
      for (final op in await db.outbox()) {
        final res = await _send(cfg, op['method'] as String, op['path'] as String, jsonDecode(op['body'] as String));
        if (res.statusCode >= 500) throw Exception('outbox ${res.statusCode}');
        await db.removeOutbox(op['id'] as int); // 4xx: se descarta para no bloquear la cola
      }

      online = true;
      lastSuccess = DateTime.now();
      return true;
    } catch (_) {
      online = false;
      return false;
    } finally {
      _running = false;
    }
  }
}
