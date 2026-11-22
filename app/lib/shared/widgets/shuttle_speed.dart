import 'package:flutter/material.dart';

const speedColors = [Color(0xFF36C665), Color(0xFFFFD600), Color(0xFFFF8900), Color(0xFFF04444)];

Color? shuttleSpeedColor(double? kmh) {
  if (kmh == null || !kmh.isFinite || kmh < 0 || kmh > 450) return null;
  if (kmh < 30) return speedColors[0];
  if (kmh < 60) return speedColors[1];
  if (kmh < 100) return speedColors[2];
  return speedColors[3];
}

typedef ShuttleTrailSample = ({Offset point, double? speed, bool approximate, bool connected});

void paintShuttleTrail(
  Canvas canvas,
  List<ShuttleTrailSample> samples, {
  required bool hasCurrent,
  double Function(int index)? ageAt,
}) {
  if (samples.isEmpty) return;
  final head = samples.last.point;
  const radius = 5.0;
  canvas.save();
  if (hasCurrent) {
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(canvas.getLocalClipBounds())
        ..addOval(Rect.fromCircle(center: head, radius: radius)),
    );
  }
  final paint = Paint()
    ..strokeWidth = 1.5
    ..strokeCap = StrokeCap.round;
  for (var i = 1; i < samples.length; i++) {
    final sample = samples[i];
    if (!sample.connected) continue;
    final age = ageAt?.call(i) ?? (samples.length - 1 - i) / samples.length;
    final confidence = sample.approximate || samples[i - 1].approximate ? 0.55 : 1.0;
    paint.color = (shuttleSpeedColor(sample.speed) ?? Colors.grey.shade400).withValues(
      alpha: (0.85 - 0.65 * age) * confidence,
    );
    canvas.drawLine(samples[i - 1].point, sample.point, paint);
  }
  canvas.restore();
  if (hasCurrent) {
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFF171717);
    canvas.drawCircle(head, radius, paint);
    paint
      ..strokeWidth = 1.25
      ..color = Colors.white;
    canvas.drawCircle(head, radius, paint);
  }
}

class ShuttleSpeedLegend extends StatelessWidget {
  const ShuttleSpeedLegend({super.key});

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      const Text('Estimated shuttle speed (km/h)'),
      for (final (index, label) in ['<30', '30–<60', '60–<100', '100+'].indexed)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: speedColors[index]),
            Text(' $label'),
          ],
        ),
    ],
  );
}
