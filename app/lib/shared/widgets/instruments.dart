import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../ui/depth.dart';

/// An analog dial for one estimated speed: a half-circle scale from 0 to [max], a lit arc up
/// to [value], a needle, and the number in the middle. Drawn on an inset screen.
class SpeedDial extends StatelessWidget {
  const SpeedDial({
    super.key,
    required this.value,
    required this.label,
    this.unit = 'km/h',
    this.max = 400,
    this.size = 220,
  });

  final double value;
  final String label;
  final String unit;
  final double max;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final t = TactileTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: '$label: ${value.round()} $unit',
      excludeSemantics: true,
      // The dial sits in a recessed box (lib/ui/depth.dart).
      child: InsetBox(
        radius: Radii.lg,
        padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, Spacing.sm),
        child: SizedBox(
          width: size,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: size,
                height: size * 0.5,
                child: CustomPaint(
                  painter: _DialPainter(
                    fraction: (value / max).clamp(0.0, 1.0),
                    track: t.recess,
                    fill: p.chart[1],
                    ticks: t.engraved,
                    needle: p.ink,
                    hub: t.raisedTop,
                  ),
                ),
              ),
              Text(
                '${value.round()}',
                style: kFigureStyle.copyWith(fontSize: size * 0.17, color: p.ink),
              ),
              const SizedBox(height: Spacing.xs),
              Text('$label · $unit', style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  const _DialPainter({
    required this.fraction,
    required this.track,
    required this.fill,
    required this.ticks,
    required this.needle,
    required this.hub,
  });

  final double fraction;
  final Color track;
  final Color fill;
  final Color ticks;
  final Color needle;
  final Color hub;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.055;
    final centre = Offset(size.width / 2, size.height - stroke);
    final radius = math.min(size.width / 2, size.height) - stroke;
    final arc = Rect.fromCircle(center: centre, radius: radius);
    final band = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas
      ..drawArc(arc, math.pi, math.pi, false, band..color = track)
      ..drawArc(arc, math.pi, math.pi * fraction, false, band..color = fill);
    final tick = Paint()
      ..color = ticks
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i <= 8; i++) {
      final a = math.pi + math.pi * i / 8;
      final dir = Offset(math.cos(a), math.sin(a));
      final inner = radius - stroke - (i.isEven ? 10 : 5);
      canvas.drawLine(centre + dir * inner, centre + dir * (radius - stroke - 2), tick);
    }
    final a = math.pi + math.pi * fraction;
    final tip = centre + Offset(math.cos(a), math.sin(a)) * (radius - stroke * 1.6);
    canvas
      ..drawLine(
        centre,
        tip,
        Paint()
          ..color = needle
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round,
      )
      ..drawCircle(centre, stroke * 0.9, Paint()..color = hub)
      ..drawCircle(
        centre,
        stroke * 0.9,
        Paint()
          ..color = ticks.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke,
      );
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.fraction != fraction ||
      old.track != track ||
      old.fill != fill ||
      old.ticks != ticks ||
      old.needle != needle ||
      old.hub != hub;
}

/// One stroke type's share as a level meter: a recessed column filled from the bottom to
/// [fraction], with the name and the count under it. It reads as a gauge, not a control:
/// there is no knob to drag.
class Fader extends StatelessWidget {
  const Fader({
    super.key,
    required this.fraction,
    required this.color,
    required this.label,
    required this.detail,
    this.semanticLabel,
    this.height = 140,
  });

  final double fraction;
  final Color color;
  final String label;
  final String detail;
  final String? semanticLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final f = fraction.clamp(0.0, 1.0);
    const width = 28.0;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InsetBox(
            width: width,
            height: height,
            radius: 10,
            padding: const EdgeInsets.all(4),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: FractionallySizedBox(
                widthFactor: 1,
                // A sliver stays visible for the smallest shares.
                heightFactor: f == 0 ? 0 : f.clamp(0.06, 1.0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color.lerp(color, Colors.white, 0.25)!, color],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Text(label, style: text.titleSmall, textAlign: TextAlign.center),
          Text(
            detail,
            style: text.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }
}
