import 'package:flutter/material.dart';

const speedColors = [Color(0xFF36C665), Color(0xFFFFD600), Color(0xFFFF8900), Color(0xFFF04444)];

Color? shuttleSpeedColor(double? kmh) {
  if (kmh == null || !kmh.isFinite || kmh < 0 || kmh > 450) return null;
  if (kmh < 30) return speedColors[0];
  if (kmh < 60) return speedColors[1];
  if (kmh < 100) return speedColors[2];
  return speedColors[3];
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
