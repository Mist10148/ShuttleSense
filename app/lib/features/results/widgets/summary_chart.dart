import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/section_card.dart';

/// F13: stroke distribution per player as grouped bars, plus hits and peak speed.
class SummaryChart extends StatelessWidget {
  const SummaryChart({super.key, required this.summary});

  final Summary? summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    if (s == null || s.totalHits == 0) return const SizedBox.shrink();
    final colors = PlayerColors.of(context);
    final theme = Theme.of(context);
    final classes = kStrokeLabels.keys.where((c) => s.strokeCounts.containsKey(c)).toList();
    int count(String side, String stroke) => s.perPlayer[side]?.strokeCounts[stroke] ?? 0;
    final maxY = [
      for (final c in classes) ...[count('near', c), count('far', c)],
    ].fold<int>(1, (a, b) => a > b ? a : b);

    String peak(String side) {
      final v = s.perPlayer[side]?.peakSpeedKmh;
      return v == null ? '–' : '${v.round()} km/h';
    }

    return SectionCard(
      title: 'Strokes by player',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (classes.isNotEmpty)
            Semantics(
              label: [
                for (final c in classes)
                  '${kStrokeLabels[c]}: near ${count('near', c)}, far ${count('far', c)}',
              ].join('; '),
              excludeSemantics: true,
              child: SizedBox(
                height: 160,
                child: BarChart(
                  BarChartData(
                    maxY: maxY.toDouble(),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: true, reservedSize: 24, interval: 1),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (value, meta) => SideTitleWidget(
                            meta: meta,
                            child: Text(
                              kStrokeLabels[classes[value.toInt()]]!.split(' ').first,
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                        ),
                      ),
                    ),
                    barGroups: [
                      for (var i = 0; i < classes.length; i++)
                        BarChartGroupData(
                          x: i,
                          barRods: [
                            BarChartRodData(
                              toY: count('near', classes[i]).toDouble(),
                              color: colors.near,
                              width: 8,
                            ),
                            BarChartRodData(
                              toY: count('far', classes[i]).toDouble(),
                              color: colors.far,
                              width: 8,
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            children: [
              for (final (side, label, color) in [
                ('near', 'Near', colors.near),
                ('far', 'Far', colors.far),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.square, size: 12, color: color),
                    const SizedBox(width: 4),
                    Text(
                      '$label: ${s.perPlayer[side]?.hits ?? 0} hits, peak ${peak(side)} (est.)',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }
}
