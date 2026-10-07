import 'dart:math';

/// Tipo de desplazamiento detectado a partir de la velocidad.
enum Activity {
  still('Detenido', 0),
  walking('Caminata', 1),
  running('Alta velocidad', 2),
  vehicle('En vehículo', 3);

  const Activity(this.label, this.code);
  final String label;
  final int code;

  static Activity fromName(String? name) =>
      Activity.values.firstWhere((a) => a.name == name, orElse: () => Activity.still);
}

double haversine(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = pow(sin(dLat / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLng / 2), 2);
  return 2 * r * asin(sqrt(a));
}

/// Calcula velocidad suavizada, tipo de actividad, distancia y calorías.
///
/// Calorías = MET × peso(kg) × horas. El MET depende de la actividad:
///  - Caminata (0.5–2.0 m/s ≈ 1.8–7.2 km/h): MET 2.0–5.0 según el ritmo (Compendium of Physical Activities).
///  - Alta velocidad / trote-carrera (2.0–6.0 m/s ≈ 7.2–21.6 km/h): MET ≈ 1.0 × km/h (8 km/h → 8.3, 12 km/h → 11.8).
///  - Más de 6 m/s se considera vehículo y no suma calorías.
class TelemetryCalculator {
  TelemetryCalculator({required this.weightKg, this.distance = 0, this.calories = 0, this.maxSpeed = 0});

  final double weightKg;
  double distance;
  double calories;
  double maxSpeed;
  double speed = 0; // m/s suavizada
  Activity activity = Activity.still;

  double? _lat, _lng;
  int? _ts;
  final _recent = <double>[];

  static const maxAccuracyForDistance = 35.0; // m

  void restoreLast(double lat, double lng, int ts) {
    _lat = lat;
    _lng = lng;
    _ts = ts;
  }

  /// Procesa una nueva lectura GPS. [gpsSpeed] puede ser negativo/nulo si el GPS no la reporta.
  void add({required double lat, required double lng, required int ts, double? gpsSpeed, double? accuracy}) {
    final goodFix = accuracy == null || accuracy <= maxAccuracyForDistance;
    if (_lat != null && _ts != null && ts > _ts!) {
      final dt = (ts - _ts!) / 1000.0;
      final d = haversine(_lat!, _lng!, lat, lng);
      // Velocidad: preferimos la del GPS (Doppler); si no existe, distancia/tiempo.
      final raw = (gpsSpeed != null && gpsSpeed >= 0) ? gpsSpeed : d / dt;
      _recent.add(raw);
      if (_recent.length > 3) _recent.removeAt(0);
      speed = _median(_recent);

      // Ignorar "saltos" de ruido GPS cuando estamos quietos o con mala precisión.
      final moving = speed > 0.5 || d > (accuracy ?? 10);
      if (goodFix && moving) {
        distance += d;
        activity = classify(speed);
        calories += met(activity, speed) * weightKg * (dt / 3600.0);
      } else if (!moving) {
        activity = Activity.still;
      }
      if (goodFix && speed > maxSpeed && speed < 70) maxSpeed = speed;
    }
    if (goodFix || _lat == null) {
      _lat = lat;
      _lng = lng;
      _ts = ts;
    }
  }

  static Activity classify(double mps) {
    if (mps < 0.5) return Activity.still;
    if (mps < 2.0) return Activity.walking;
    if (mps < 6.0) return Activity.running;
    return Activity.vehicle;
  }

  static double met(Activity a, double mps) {
    final kmh = mps * 3.6;
    switch (a) {
      case Activity.walking:
        if (kmh < 3.2) return 2.0;
        if (kmh < 4.8) return 3.0;
        if (kmh < 5.6) return 3.5;
        if (kmh < 6.4) return 4.3;
        return 5.0;
      case Activity.running:
        return max(6.0, kmh * 0.98);
      case Activity.still:
      case Activity.vehicle:
        return 0;
    }
  }

  static double _median(List<double> v) {
    final s = [...v]..sort();
    return s[s.length ~/ 2];
  }
}
