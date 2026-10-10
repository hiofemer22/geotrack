import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/telemetry.dart';
import 'theme.dart';

/// Tarjeta translúcida con desenfoque, como los paneles de Google Maps.
class FloatingCard extends StatelessWidget {
  const FloatingCard({super.key, required this.child, this.radius = 16, this.padding = const EdgeInsets.all(16)});
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(radius), boxShadow: floatingShadow),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(color: Palette.surface, padding: padding, child: child),
        ),
      ),
    );
  }
}

class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.tracking, required this.online, required this.pending, this.accuracy});
  final bool tracking;
  final bool? online;
  final int pending;
  final double? accuracy; // m

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late String text;
    if (!tracking) {
      color = Palette.muted;
      text = 'Rastreo detenido';
    } else if (online == false) {
      color = Palette.warning;
      text = 'Sin conexión · $pending puntos guardados';
    } else if (pending > 0) {
      color = Palette.primary;
      text = 'Sincronizando $pending…';
    } else {
      color = Palette.success;
      text = 'Rastreo activo · sincronizado';
    }
    if (accuracy != null) text += ' · GPS ±${accuracy!.round()} m';
    return Row(children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: const TextStyle(fontSize: 12, color: Palette.muted), overflow: TextOverflow.ellipsis)),
    ]);
  }
}

/// Punto azul de "mi ubicación" con halo y cono de dirección.
class MyLocationDot extends StatefulWidget {
  const MyLocationDot({super.key, this.heading, this.active = false});
  final double? heading;
  final bool active;

  @override
  State<MyLocationDot> createState() => _MyLocationDotState();
}

class _MyLocationDotState extends State<MyLocationDot> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Stack(alignment: Alignment.center, children: [
        if (widget.active)
          Container(
            width: 18 + 26 * _anim.value,
            height: 18 + 26 * _anim.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Palette.primary.withValues(alpha: 0.25 * (1 - _anim.value)),
            ),
          ),
        if (widget.heading != null && widget.heading! > 0)
          Transform.rotate(
            angle: widget.heading! * pi / 180,
            child: const Align(
              alignment: Alignment.topCenter,
              child: Icon(Icons.navigation, size: 16, color: Palette.primary),
            ),
          ),
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: Palette.primary,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
          ),
        ),
      ]),
    );
  }
}

class RoundFab extends StatelessWidget {
  const RoundFab({super.key, required this.icon, required this.onPressed, this.color = Palette.muted});
  final IconData icon;
  final VoidCallback onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white, boxShadow: floatingShadow),
      child: IconButton(icon: Icon(icon, color: color), onPressed: onPressed, iconSize: 24, padding: const EdgeInsets.all(12)),
    );
  }
}

/// Botón principal Iniciar/Detener (pastilla grande, estilo "Iniciar" de Google Maps).
class TrackButton extends StatelessWidget {
  const TrackButton({super.key, required this.tracking, required this.busy, required this.onPressed});
  final bool tracking;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final color = tracking ? Palette.danger : Palette.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6))],
      ),
      child: FilledButton.icon(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          minimumSize: const Size(200, 60),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500, letterSpacing: 0.3),
        ),
        icon: busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : Icon(tracking ? Icons.stop_rounded : Icons.navigation_rounded, size: 26),
        label: Text(tracking ? 'Detener' : 'Iniciar'),
      ),
    );
  }
}

class TelemetryCard extends StatelessWidget {
  const TelemetryCard({
    super.key,
    required this.speedMps,
    required this.distanceM,
    required this.calories,
    required this.elapsed,
    required this.activity,
  });
  final double speedMps;
  final double distanceM;
  final double calories;
  final Duration elapsed;
  final Activity activity;

  static IconData iconFor(Activity a) => switch (a) {
        Activity.still => Icons.accessibility_new,
        Activity.walking => Icons.directions_walk,
        Activity.running => Icons.directions_run,
        Activity.vehicle => Icons.directions_car,
      };

  @override
  Widget build(BuildContext context) {
    final color = switch (activity) {
      Activity.running => Palette.danger,
      Activity.walking => Palette.success,
      Activity.vehicle => Palette.primary,
      Activity.still => Palette.muted,
    };
    return FloatingCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text((speedMps * 3.6).toStringAsFixed(1),
                  style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w400, height: 1, color: Palette.text)),
              const Padding(
                padding: EdgeInsets.only(left: 6, bottom: 4),
                child: Text('km/h', style: TextStyle(fontSize: 15, color: Palette.muted)),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(16)),
                child: Row(children: [
                  Icon(iconFor(activity), size: 18, color: color),
                  const SizedBox(width: 4),
                  Text(activity.label, style: TextStyle(color: color, fontWeight: FontWeight.w500, fontSize: 13)),
                ]),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1, color: Color(0xFFE3E5E8)),
          const SizedBox(height: 12),
          Row(
            children: [
              _Metric(icon: Icons.straighten, value: fmtDistance(distanceM), label: 'Distancia'),
              _Metric(icon: Icons.timer_outlined, value: fmtDuration(elapsed), label: 'Tiempo'),
              _Metric(icon: Icons.local_fire_department_outlined, value: '${calories.toStringAsFixed(0)} kcal', label: 'Calorías'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.value, required this.label});
  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(children: [
        Icon(icon, size: 18, color: Palette.primary),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15)),
        Text(label, style: const TextStyle(fontSize: 11, color: Palette.muted)),
      ]),
    );
  }
}

/// Botón SOS: hay que mantenerlo presionado 2 s para evitar envíos accidentales.
class SosButton extends StatefulWidget {
  const SosButton({super.key, required this.onTriggered});
  final VoidCallback onTriggered;

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        widget.onTriggered();
        _ctrl.reset();
      }
    });

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) => _ctrl.reverse(),
      onTapCancel: () => _ctrl.reverse(),
      onTap: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Mantén presionado SOS durante 2 segundos para enviar una alerta'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      )),
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) => SizedBox(
          width: 48,
          height: 48,
          child: Stack(alignment: Alignment.center, children: [
            Container(
              decoration: const BoxDecoration(shape: BoxShape.circle, color: Palette.danger, boxShadow: floatingShadow),
            ),
            CircularProgressIndicator(value: _ctrl.value, strokeWidth: 3, color: Colors.white),
            const Text('SOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}
