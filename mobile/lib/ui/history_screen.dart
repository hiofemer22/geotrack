import 'package:flutter/material.dart';

import '../data/local_db.dart';
import '../data/models.dart';
import 'session_detail_screen.dart';
import 'theme.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Session>? _sessions;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = await LocalDb.open();
    final list = await db.listSessions();
    if (mounted) setState(() => _sessions = list);
  }

  @override
  Widget build(BuildContext context) {
    final sessions = _sessions;
    return Scaffold(
      appBar: AppBar(title: const Text('Mis recorridos')),
      body: sessions == null
          ? const Center(child: CircularProgressIndicator())
          : sessions.isEmpty
              ? const _Empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: sessions.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 76),
                    itemBuilder: (_, i) {
                      final s = sessions[i];
                      final active = s.endedAt == null;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        leading: CircleAvatar(
                          radius: 24,
                          backgroundColor: active ? Palette.success.withValues(alpha: 0.12) : Palette.hover,
                          child: Icon(active ? Icons.radio_button_checked : Icons.route,
                              color: active ? Palette.success : Palette.primary),
                        ),
                        title: Text(s.displayName,
                            style: const TextStyle(fontWeight: FontWeight.w500)),
                        subtitle: Text(
                          '${fmtDistance(s.distance)} · ${fmtDuration(s.duration)} · ${s.calories.toStringAsFixed(0)} kcal'
                          '${active ? ' · en curso' : ''}',
                          style: const TextStyle(color: Palette.muted),
                        ),
                        trailing: const Icon(Icons.chevron_right, color: Palette.muted),
                        onTap: () async {
                          await Navigator.push(
                              context, MaterialPageRoute(builder: (_) => SessionDetailScreen(session: s)));
                          _load();
                        },
                      );
                    },
                  ),
                ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.map_outlined, size: 64, color: Palette.muted),
          SizedBox(height: 12),
          Text('Aún no hay recorridos', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
          SizedBox(height: 4),
          Text('Pulsa "Iniciar" en el mapa para grabar tu primera ruta.',
              textAlign: TextAlign.center, style: TextStyle(color: Palette.muted)),
        ]),
      ),
    );
  }
}
