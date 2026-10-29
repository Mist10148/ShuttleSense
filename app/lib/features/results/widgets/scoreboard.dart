import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/section_card.dart';

/// F16: assisted scoreboard. Corrections arrive in T6.5.
class Scoreboard extends StatelessWidget {
  const Scoreboard({super.key, this.score, this.summary});

  final Score? score;
  final Summary? summary;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final theme = Theme.of(context);
    return SectionCard(
      title: 'Score and stats',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (score == null)
            Text('Enable the referee layer to keep score.', style: theme.textTheme.bodySmall)
          else
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _Side(label: 'Near', points: score!.near, color: colors.near),
                Text(':', style: theme.textTheme.headlineMedium),
                _Side(label: 'Far', points: score!.far, color: colors.far),
              ],
            ),
          if (summary != null && summary!.strokeCounts.isNotEmpty) ...[
            const Divider(height: 24),
            for (final e in summary!.strokeCounts.entries)
              Row(
                children: [
                  Expanded(child: Text(kStrokeLabels[e.key] ?? e.key)),
                  Text('${e.value}'),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({required this.label, required this.points, required this.color});

  final String label;
  final int points;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.w600),
        ),
        Text('$points', style: Theme.of(context).textTheme.displaySmall),
      ],
    );
  }
}
