import 'package:flutter/material.dart';

/// Rally state, estimated speed and stroke count under the video (F11, F12, F14).
class StatusStrip extends StatelessWidget {
  const StatusStrip({
    super.key,
    this.rallyState,
    this.speedKmh,
    this.peakSpeedKmh,
    required this.strokeCount,
  });

  final String? rallyState;
  final double? speedKmh;
  final double? peakSpeedKmh;
  final int strokeCount;

  @override
  Widget build(BuildContext context) {
    String kmh(double? v) => v == null ? '–' : '${v.round()} km/h';
    final state = switch (rallyState) {
      'in_play' => 'IN PLAY',
      'between_rallies' => 'BETWEEN RALLIES',
      _ => '–',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Pill(icon: Icons.flag_outlined, label: state),
          _Pill(icon: Icons.speed, label: 'Speed ${kmh(speedKmh)} (est.)'),
          _Pill(icon: Icons.trending_up, label: 'Peak ${kmh(peakSpeedKmh)} (est.)'),
          _Pill(icon: Icons.sports_tennis, label: 'Strokes $strokeCount'),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
