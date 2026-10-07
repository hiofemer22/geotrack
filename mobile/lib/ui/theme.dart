import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

class Palette {
  static const primary = Color(0xFF1A73E8);
  static const danger = Color(0xFFD93025);
  static const success = Color(0xFF188038);
  static const warning = Color(0xFFF9AB00);
  static const text = Color(0xFF202124);
  static const muted = Color(0xFF5F6368);
  static const surface = Color(0xF2FFFFFF); // blanco translúcido
  static const hover = Color(0xFFF1F3F4);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: Palette.primary, primary: Palette.primary, surface: Colors.white);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Palette.text,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w500, color: Palette.text),
    ),
    cardTheme: const CardThemeData(color: Colors.white, elevation: 0, margin: EdgeInsets.zero),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.hover,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    ),
  );
}

/// Sombra suave estilo Google Maps para elementos flotantes.
const floatingShadow = [
  BoxShadow(color: Color(0x4D3C4043), blurRadius: 2, offset: Offset(0, 1)),
  BoxShadow(color: Color(0x263C4043), blurRadius: 6, spreadRadius: 2, offset: Offset(0, 2)),
];

/// Mapa base OpenStreetMap (sin API key; CARTO ahora la exige).
TileLayer baseTiles() => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'com.geotrack.mobile',
      maxNativeZoom: 19,
      maxZoom: 20,
    );

String fmtDistance(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(2)} km' : '${m.toStringAsFixed(0)} m';

String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m ${s.toString().padLeft(2, '0')}s';
}
