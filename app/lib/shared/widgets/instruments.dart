import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'tactile.dart';

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
      child: InsetScreen(
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

/// One channel of a mixing-desk fader bank: a sunken track filled to [fraction] with a knob
/// on top, and a label under it. Read-only: it shows a share, it is not a control.
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
    final t = TactileTokens.of(context);
    final text = Theme.of(context).textTheme;
    final f = fraction.clamp(0.0, 1.0);
    const trackWidth = 12.0;
    const knobHeight = 22.0;
    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: height,
            child: Stack(
              alignment: Alignment.bottomCenter,
              clipBehavior: Clip.none,
              children: [
                Recess(
                  radius: Radii.pill,
                  padding: EdgeInsets.zero,
                  depth: 2,
                  child: SizedBox(
                    width: trackWidth,
                    height: height,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: f,
                        widthFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(Radii.pill),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: (height - knobHeight) * f,
                  child: Container(
                    width: 40,
                    height: knobHeight,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      gradient: raisedGradient(t),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: t.rim),
                      boxShadow: [
                        BoxShadow(color: t.shade, blurRadius: 6, offset: const Offset(0, 3)),
                      ],
                    ),
                    child: Container(width: 22, height: 2, color: color),
                  ),
                ),
              ],
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
