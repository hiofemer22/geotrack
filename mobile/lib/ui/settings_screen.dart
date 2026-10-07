import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../data/local_db.dart';
import '../services/sync_service.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppConfig? _cfg;
  final _server = TextEditingController();
  final _apiKey = TextEditingController();
  final _name = TextEditingController();
  final _weight = TextEditingController();
  int _interval = 5;
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    AppConfig.load().then((c) {
      setState(() {
        _cfg = c;
        _server.text = c.serverUrl;
        _apiKey.text = c.apiKey;
        _name.text = c.deviceName;
        _weight.text = c.weightKg.toStringAsFixed(0);
        _interval = c.intervalSec;
      });
    });
  }

  Future<void> _save() async {
    await _cfg!.save(
      serverUrl: _server.text,
      apiKey: _apiKey.text,
      deviceName: _name.text,
      weightKg: double.tryParse(_weight.text.replaceAll(',', '.')),
      intervalSec: _interval,
    );
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    await _save();
    try {
      final cfg = await AppConfig.load();
      final res = await http.get(Uri.parse('${cfg.serverUrl}/api/health')).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      await SyncService(await LocalDb.open()).register(cfg);
      _testResult = '✅ Conectado y dispositivo registrado';
    } catch (e) {
      _testResult = '❌ No se pudo conectar: $e';
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_cfg == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return PopScope(
      onPopInvokedWithResult: (_, _) => _save(),
      child: Scaffold(
        appBar: AppBar(title: const Text('Ajustes')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _Section('Dispositivo'),
            TextField(controller: _name, decoration: const InputDecoration(labelText: 'Nombre visible en el monitoreo', prefixIcon: Icon(Icons.badge_outlined))),
            const SizedBox(height: 12),
            TextField(
              controller: _weight,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Peso (kg) para calcular calorías', prefixIcon: Icon(Icons.monitor_weight_outlined)),
            ),
            const SizedBox(height: 20),
            const _Section('Frecuencia de captura'),
            Row(children: [
              Expanded(
                child: Slider(
                  value: _interval.toDouble(),
                  min: 5,
                  max: 10,
                  divisions: 5,
                  label: '$_interval s',
                  onChanged: (v) => setState(() => _interval = v.round()),
                ),
              ),
              Text('cada $_interval s', style: const TextStyle(color: Palette.muted)),
            ]),
            const Text('Se aplica al iniciar el siguiente rastreo.', style: TextStyle(fontSize: 12, color: Palette.muted)),
            const SizedBox(height: 20),
            const _Section('Servidor'),
            TextField(
              controller: _server,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(labelText: 'URL del servidor', hintText: 'http://IP-o-dominio:8080', prefixIcon: Icon(Icons.dns_outlined)),
            ),
            const SizedBox(height: 12),
            TextField(controller: _apiKey, decoration: const InputDecoration(labelText: 'Clave del dispositivo (API key)', prefixIcon: Icon(Icons.key_outlined))),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_tethering),
              label: const Text('Guardar y probar conexión'),
            ),
            if (_testResult != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_testResult!)),
            const SizedBox(height: 24),
            Text('ID del dispositivo: ${_cfg!.deviceId}', style: const TextStyle(fontSize: 11, color: Palette.muted)),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(title, style: const TextStyle(color: Palette.primary, fontWeight: FontWeight.w500)),
      );
}
