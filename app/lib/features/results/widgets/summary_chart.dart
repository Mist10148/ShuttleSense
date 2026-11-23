import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../data/models/job.dart';
import '../../../shared/widgets/section_card.dart';

/// F13: stroke distribution per player as grouped bars, plus hits and peak speed.
class SummaryChart extends StatelessWidget {
  const SummaryChart({super.key, required this.summary, this.strokeModel});

  final Summary? summary;

  /// The classifier that named the strokes (cnn, lstm, rf), shown under the title.
  final String? strokeModel;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    if (s == null || s.totalHits == 0) return const SizedBox.shrink();
    final colors = PlayerColors.of(context);
    final theme = Theme.of(context);
    final classes = kStrokeLabels.keys.where((c) => s.strokeCounts.containsKey(c)).toList();
    // Doubles: one bar per partner (hits whose partner is unknown count only for the side).
    final players = s.perPlayer.containsKey('near_1')
        ? const ['near_1', 'near_2', 'far_1', 'far_2']
        : const ['near', 'far'];
    int count(String side, String stroke) => s.perPlayer[side]?.strokeCounts[stroke] ?? 0;
    final maxY = [
      for (final c in classes)
        for (final p in players) count(p, c),
    ].fold<int>(1, (a, b) => a > b ? a : b);

    String peak(String side) {
      final v = s.perPlayer[side]?.peakSpeedKmh;
      return v == null ? '–' : '${v.round()} km/h';
    }

    // Inside the Stats tab's panel: a titled block, not a card of its own.
    return SectionBlock(
      title: 'Strokes by player',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (classes.isNotEmpty && kStrokeModels.containsKey(strokeModel))
            Padding(
              padding: const EdgeInsets.only(bottom: Spacing.sm),
              child: Text(
                'Strokes named by the ${kStrokeModels[strokeModel]} model',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (classes.isNotEmpty)
            Semantics(
              label: [
                for (final c in classes)
                  '${kStrokeLabels[c]}: '
                      '${[for (final p in players) '${playerLabel(p).toLowerCase()} ${count(p, c)}'].join(', ')}',
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
                            for (final p in players)
                              BarChartRodData(
                                toY: count(p, classes[i]).toDouble(),
                                color: colors.forPlayer(p),
                                width: players.length > 2 ? 6 : 8,
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: 16,
            children: [
              for (final (side, label, color) in [
                for (final p in players) (p, playerLabel(p), colors.forPlayer(p)),
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.square, size: 12, color: color),
                    const SizedBox(width: Spacing.xs),
                    // Flexible: a narrow side panel wraps the label instead of overflowing.
                    Flexible(
                      child: Text(
                        '$label: ${s.perPlayer[side]?.hits ?? 0} hits, peak ${peak(side)} (est.)',
                        style: theme.textTheme.bodySmall,
                      ),
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
