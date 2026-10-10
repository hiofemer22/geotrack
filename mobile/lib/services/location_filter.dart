import 'dart:math';

import 'telemetry.dart';

/// Posición ya filtrada lista para guardar o dibujar.
class FilteredFix {
  const FilteredFix(this.lat, this.lng, this.accuracy);
  final double lat;
  final double lng;
  final double accuracy; // m, incertidumbre estimada tras el filtro
}

/// Limpia las lecturas del GPS antes de usarlas:
///  1. Descarta lecturas imprecisas (las de Wi-Fi/antenas reportan 50–2000 m y son las que "teletransportan").
///  2. Descarta saltos físicamente imposibles respecto a la última posición aceptada.
///  3. Suaviza con un filtro de Kalman que predice con la velocidad y rumbo del GPS, así no se queda atrás en movimiento.
///  4. Estando quieto fija la posición en el promedio ponderado de las lecturas (pesa más las precisas),
///     en vez de moverse 3–5 m con cada una.
class LocationFilter {
  static const maxAccuracy = 25.0; // m, umbral normal
  static const relaxedAccuracy = 40.0; // m, si llevamos un rato sin lecturas buenas (p. ej. bajo techo)
  static const relaxAfterMs = 20000;
  static const maxSpeed = 50.0; // m/s (180 km/h)
  static const processNoise = 2.0; // m/s detenido/caminando; crece con la velocidad (curvas, frenadas)
  static const gapResetMs = 10000; // tras una pausa del GPS la estimación vieja ya no sirve
  static const resetAfterRejections = 5;
  static const stillSpeed = 0.5; // m/s, por debajo se considera quieto
  static const moveSpeed = 1.0; // m/s, por encima sale del modo quieto
  static const stillToEnter = 3; // lecturas quietas seguidas para fijar la posición
  static const moveToExit = 2; // lecturas lejos del punto fijo para soltarlo
  static const stillMemory = 0.98; // olvido gradual: pesan más los últimos ~50 s

  double? _lat, _lng;
  double _variance = 0; // m²
  int _ts = 0;
  int _rejected = 0;

  // Modo quieto: promedio ponderado (peso = 1/precisión²) de las lecturas
  bool _still = false;
  int _stillVotes = 0, _moveVotes = 0;
  double _sumW = 0, _sumLat = 0, _sumLng = 0;

  bool get isStill => _still;

  /// Devuelve la posición filtrada, o null si la lectura debe ignorarse.
  FilteredFix? add({
    required double lat,
    required double lng,
    required double accuracy,
    required int ts,
    double? speed,
    double? heading,
  }) {
    final acc = max(accuracy, 1.0);
    if (_lat == null) {
      if (acc > maxAccuracy) return null;
      return _reset(lat, lng, acc, ts);
    }
    if (ts <= _ts) return null;

    final dtMs = ts - _ts;
    final limit = dtMs > relaxAfterMs ? relaxedAccuracy : maxAccuracy;
    if (acc > limit) return null;

    final dt = dtMs / 1000.0;
    final d = haversine(_lat!, _lng!, lat, lng);
    if (d - acc - sqrt(_variance) > maxSpeed * dt) {
      // Si varias lecturas precisas seguidas coinciden en otro lugar, la equivocada era la anterior.
      if (++_rejected >= resetAfterRejections) return _reset(lat, lng, acc, ts);
      return null;
    }
    _rejected = 0;
    if (dtMs > gapResetMs) return _reset(lat, lng, acc, ts);

    // Predicción: avanzar según la velocidad y rumbo que reporta el GPS (Doppler).
    if (speed != null && speed > 0.5 && heading != null && heading >= 0) {
      final step = speed * dt;
      final h = heading * pi / 180;
      _lat = _lat! + (step * cos(h)) / 111320.0;
      _lng = _lng! + (step * sin(h)) / (111320.0 * cos(_lat! * pi / 180));
    }
    final q = processNoise + 0.5 * max(speed ?? 0, 0);
    _variance += dt * q * q;

    // Corrección con la medición, ponderada por su precisión.
    final k = _variance / (_variance + acc * acc);
    _lat = _lat! + k * (lat - _lat!);
    _lng = _lng! + k * (lng - _lng!);
    _variance = (1 - k) * _variance;
    _ts = ts;
    return _stillOrMoving(lat, lng, acc, speed);
  }

  FilteredFix _stillOrMoving(double lat, double lng, double acc, double? speed) {
    final slow = speed == null || speed < 0 || speed < stillSpeed;
    if (_still) {
      final anchorLat = _sumLat / _sumW, anchorLng = _sumLng / _sumW;
      final away = haversine(anchorLat, anchorLng, lat, lng) > max(2 * acc, 8.0);
      final fast = speed != null && speed > moveSpeed;
      _moveVotes = (away || fast) ? _moveVotes + 1 : 0;
      if (_moveVotes >= moveToExit || (speed != null && speed > 2 * moveSpeed)) {
        _still = false; // el Kalman siguió actualizándose, así que ya está al día
        _stillVotes = 0;
      } else {
        if (!away) _accumulate(lat, lng, acc);
        return FilteredFix(_sumLat / _sumW, _sumLng / _sumW, sqrt(_variance));
      }
    } else {
      _stillVotes = slow ? _stillVotes + 1 : 0;
      if (_stillVotes >= stillToEnter) {
        _still = true;
        _moveVotes = 0;
        _sumW = 1 / _variance; // arranca desde la estimación actual del Kalman
        _sumLat = _lat! * _sumW;
        _sumLng = _lng! * _sumW;
        return FilteredFix(_lat!, _lng!, sqrt(_variance));
      }
    }
    return FilteredFix(_lat!, _lng!, sqrt(_variance));
  }

  void _accumulate(double lat, double lng, double acc) {
    final w = 1 / (acc * acc);
    _sumW = _sumW * stillMemory + w;
    _sumLat = _sumLat * stillMemory + lat * w;
    _sumLng = _sumLng * stillMemory + lng * w;
  }

  FilteredFix _reset(double lat, double lng, double acc, int ts) {
    _lat = lat;
    _lng = lng;
    _variance = acc * acc;
    _ts = ts;
    _rejected = 0;
    _still = false;
    _stillVotes = 0;
    return FilteredFix(lat, lng, acc);
  }
}
