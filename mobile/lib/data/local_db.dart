import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'models.dart';

/// Base de datos local (SQLite). Guarda el historial on-device y funciona como
/// cola de salida: todo punto u operación con synced = 0 está pendiente de enviar.
class LocalDb {
  LocalDb._(this.db);
  final Database db;

  static LocalDb? _instance;

  static Future<LocalDb> open() async {
    if (_instance != null) return _instance!;
    final path = p.join(await getDatabasesPath(), 'geotrack.db');
    final db = await openDatabase(
      path,
      version: 1,
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.rawQuery('PRAGMA busy_timeout=5000');
      },
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            name TEXT,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            distance REAL NOT NULL DEFAULT 0,
            calories REAL NOT NULL DEFAULT 0,
            max_speed REAL NOT NULL DEFAULT 0
          )''');
        await db.execute('''
          CREATE TABLE points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            ts INTEGER NOT NULL,
            lat REAL NOT NULL,
            lng REAL NOT NULL,
            speed REAL,
            accuracy REAL,
            heading REAL,
            altitude REAL,
            battery INTEGER,
            activity TEXT,
            synced INTEGER NOT NULL DEFAULT 0
          )''');
        await db.execute('CREATE INDEX points_session ON points(session_id, ts)');
        await db.execute('CREATE INDEX points_unsynced ON points(synced, ts)');
        await db.execute('''
          CREATE TABLE outbox (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            method TEXT NOT NULL,
            path TEXT NOT NULL,
            body TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )''');
      },
    );
    return _instance = LocalDb._(db);
  }

  // ------------------------------------------------------------ sesiones
  Future<void> insertSession(Session s) => db.insert('sessions', s.toMap());

  Future<Session?> getSession(String id) async {
    final rows = await db.query('sessions', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Session.fromMap(rows.first);
  }

  Future<List<Session>> listSessions() async {
    final rows = await db.rawQuery('''
      SELECT s.*, (SELECT COUNT(*) FROM points p WHERE p.session_id = s.id) AS point_count
      FROM sessions s ORDER BY started_at DESC''');
    return rows.map(Session.fromMap).toList();
  }

  Future<void> updateSessionTotals(String id, {required double distance, required double calories, required double maxSpeed}) =>
      db.update('sessions', {'distance': distance, 'calories': calories, 'max_speed': maxSpeed},
          where: 'id = ?', whereArgs: [id]);

  Future<void> endSession(String id, int endedAt) =>
      db.update('sessions', {'ended_at': endedAt}, where: 'id = ?', whereArgs: [id]);

  Future<void> renameSession(String id, String name) =>
      db.update('sessions', {'name': name}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteSession(String id) async {
    await db.delete('points', where: 'session_id = ?', whereArgs: [id]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  // ------------------------------------------------------------ puntos
  Future<void> insertPoint(TrackPoint pt) => db.insert('points', pt.toMap());

  Future<List<TrackPoint>> pointsFor(String sessionId) async {
    final rows = await db.query('points', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'ts');
    return rows.map(TrackPoint.fromMap).toList();
  }

  Future<TrackPoint?> lastPoint(String sessionId) async {
    final rows = await db.query('points',
        where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'ts DESC', limit: 1);
    return rows.isEmpty ? null : TrackPoint.fromMap(rows.first);
  }

  Future<List<TrackPoint>> unsyncedPoints({int limit = 500}) async {
    final rows = await db.query('points', where: 'synced = 0', orderBy: 'ts', limit: limit);
    return rows.map(TrackPoint.fromMap).toList();
  }

  Future<void> markSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    await db.rawUpdate('UPDATE points SET synced = 1 WHERE id IN (${List.filled(ids.length, '?').join(',')})', ids);
  }

  Future<int> pendingCount() async {
    final a = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM points WHERE synced = 0')) ?? 0;
    final b = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM outbox')) ?? 0;
    return a + b;
  }

  // ------------------------------------------------------------ operaciones pendientes
  Future<void> enqueue(String method, String path, Map<String, dynamic> body) => db.insert('outbox', {
        'method': method,
        'path': path,
        'body': jsonEncode(body),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

  Future<List<Map<String, Object?>>> outbox() => db.query('outbox', orderBy: 'id');

  Future<void> removeOutbox(int id) => db.delete('outbox', where: 'id = ?', whereArgs: [id]);
}
