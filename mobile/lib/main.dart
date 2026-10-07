import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/tracking_service.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));
  await TrackingService.initialize();
  runApp(const GeoTrackApp());
}

class GeoTrackApp extends StatelessWidget {
  const GeoTrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoTrack',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const HomeScreen(),
    );
  }
}
