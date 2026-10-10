import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/local_db.dart';
import '../data/models.dart';
import '../services/location_filter.dart';
import '../services/tracking_service.dart';
import 'theme.dart';
import 'widgets.dart';

class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.session});
  final Session session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  List<TrackPoint>? _points;
  late final Session _s = widget.session;

  @override
  void initState() {
    super.initState();
    LocalDb.open().then((db) => db.pointsFor(_s.id)).then((p) {
      // Rutas grabadas antes del filtro: ocultar las lecturas imprecisas que "teletransportaban"
      final clean = p.where((x) => x.accuracy == null || x.accuracy! <= LocationFilter.relaxedAccuracy).toList();
      if (mounted) setState(() => _points = clean);
    });
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _s.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nombre del recorrido'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Ej. Ruta de entrega zona norte'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Guardar')),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await TrackingService.renameSession(_s.id, name.trim());
    setState(() => _s.name = name.trim());
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Eliminar recorrido?'),
        content: const Text('Se borrará de este teléfono. Los datos ya enviados al servidor se conservan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await (await LocalDb.open()).deleteSession(_s.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final pts = _points;
    final route = pts?.map((p) => LatLng(p.lat, p.lng)).toList() ?? [];
    final pad = MediaQuery.of(context).padding;

    return Scaffold(
      body: Stack(
        children: [
          if (pts == null)
            const Center(child: CircularProgressIndicator())
          else if (route.isEmpty)
            const Center(child: Text('Este recorrido no tiene puntos registrados.'))
          else
            FlutterMap(
              options: MapOptions(
                initialCameraFit: route.length > 1
                    ? CameraFit.bounds(
                        bounds: LatLngBounds.fromPoints(route),
                        padding: EdgeInsets.fromLTRB(48, pad.top + 90, 48, 260),
                      )
                    : null,
                initialCenter: route.first,
                initialZoom: 16,
              ),
              children: [
                baseTiles(),
                PolylineLayer(polylines: [
                  Polyline(points: route, strokeWidth: 9, color: Colors.white),
                  Polyline(points: route, strokeWidth: 5.5, color: Palette.primary),
                ]),
                MarkerLayer(markers: [
                  Marker(point: route.first, width: 22, height: 22, child: const _Pin(color: Palette.success)),
                  if (route.length > 1)
                    Marker(point: route.last, width: 22, height: 22, child: const _Pin(color: Palette.danger)),
                ]),
              ],
            ),

          // Barra superior
          Positioned(
            top: pad.top + 12,
            left: 16,
            right: 16,
            child: FloatingCard(
              radius: 28,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(children: [
                IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
                Expanded(
                  child: GestureDetector(
                    onTap: _rename,
                    child: Text(_s.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                  ),
                ),
                IconButton(tooltip: 'Renombrar', icon: const Icon(Icons.edit_outlined, color: Palette.muted), onPressed: _rename),
                IconButton(tooltip: 'Eliminar', icon: const Icon(Icons.delete_outline, color: Palette.muted), onPressed: _delete),
              ]),
            ),
          ),

          // Resumen
          Positioned(
            left: 16,
            right: 16,
            bottom: pad.bottom + 20,
            child: FloatingCard(
              radius: 20,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  _Stat(Icons.straighten, fmtDistance(_s.distance), 'Distancia'),
                  _Stat(Icons.timer_outlined, fmtDuration(_s.duration), 'Duración'),
                ]),
                const SizedBox(height: 16),
                Row(children: [
                  _Stat(Icons.local_fire_department_outlined, '${_s.calories.toStringAsFixed(0)} kcal', 'Calorías'),
                  _Stat(Icons.speed, '${(_s.maxSpeed * 3.6).toStringAsFixed(1)} km/h', 'Vel. máxima'),
                ]),
                if (pts != null) ...[
                  const SizedBox(height: 12),
                  Text('${pts.length} puntos GPS', style: const TextStyle(fontSize: 12, color: Palette.muted)),
                ],
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.icon, this.value, this.label);
  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: Palette.primary.withValues(alpha: 0.1), shape: BoxShape.circle),
          child: Icon(icon, size: 20, color: Palette.primary),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
          Text(label, style: const TextStyle(fontSize: 12, color: Palette.muted)),
        ]),
      ]),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
        ),
      );
}
