class Session {
  Session({
    required this.id,
    required this.startedAt,
    this.name,
    this.endedAt,
    this.distance = 0,
    this.calories = 0,
    this.maxSpeed = 0,
    this.pointCount = 0,
  });

  final String id;
  String? name;
  final int startedAt;
  int? endedAt;
  double distance; // metros
  double calories; // kcal
  double maxSpeed; // m/s
  int pointCount;

  /// Nombre personalizado o, si no tiene, "Recorrido del 6 oct, 14:05".
  String get displayName {
    if (name != null && name!.isNotEmpty) return name!;
    final d = DateTime.fromMillisecondsSinceEpoch(startedAt);
    const months = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];
    return 'Recorrido del ${d.day} ${months[d.month - 1]}, '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Duration get duration =>
      Duration(milliseconds: (endedAt ?? DateTime.now().millisecondsSinceEpoch) - startedAt);

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'started_at': startedAt,
        'ended_at': endedAt,
        'distance': distance,
        'calories': calories,
        'max_speed': maxSpeed,
      };

  static Session fromMap(Map<String, Object?> m) => Session(
        id: m['id'] as String,
        name: m['name'] as String?,
        startedAt: m['started_at'] as int,
        endedAt: m['ended_at'] as int?,
        distance: (m['distance'] as num?)?.toDouble() ?? 0,
        calories: (m['calories'] as num?)?.toDouble() ?? 0,
        maxSpeed: (m['max_speed'] as num?)?.toDouble() ?? 0,
        pointCount: (m['point_count'] as int?) ?? 0,
      );
}

class TrackPoint {
  TrackPoint({
    this.id,
    required this.sessionId,
    required this.ts,
    required this.lat,
    required this.lng,
    this.speed,
    this.accuracy,
    this.heading,
    this.altitude,
    this.battery,
    this.activity,
  });

  final int? id;
  final String sessionId;
  final int ts; // epoch ms
  final double lat;
  final double lng;
  final double? speed; // m/s
  final double? accuracy;
  final double? heading;
  final double? altitude;
  final int? battery;
  final String? activity;

  Map<String, Object?> toMap() => {
        if (id != null) 'id': id,
        'session_id': sessionId,
        'ts': ts,
        'lat': lat,
        'lng': lng,
        'speed': speed,
        'accuracy': accuracy,
        'heading': heading,
        'altitude': altitude,
        'battery': battery,
        'activity': activity,
      };

  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'ts': ts,
        'lat': lat,
        'lng': lng,
        'speed': speed,
        'accuracy': accuracy,
        'heading': heading,
        'altitude': altitude,
        'battery': battery,
        'activity': activity,
      };

  static TrackPoint fromMap(Map<String, Object?> m) => TrackPoint(
        id: m['id'] as int?,
        sessionId: m['session_id'] as String,
        ts: m['ts'] as int,
        lat: (m['lat'] as num).toDouble(),
        lng: (m['lng'] as num).toDouble(),
        speed: (m['speed'] as num?)?.toDouble(),
        accuracy: (m['accuracy'] as num?)?.toDouble(),
        heading: (m['heading'] as num?)?.toDouble(),
        altitude: (m['altitude'] as num?)?.toDouble(),
        battery: m['battery'] as int?,
        activity: m['activity'] as String?,
      );
}
