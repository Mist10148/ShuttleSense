import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/section_card.dart';

/// F14/F16: assisted scoreboard at the current playback position, with per-rally winner
/// chips to correct the referee layer's calls.
class Scoreboard extends StatelessWidget {
  const Scoreboard({
    super.key,
    required this.record,
    required this.frameIndex,
    this.onCorrect,
    this.busy = false,
  });

  final ClipRecord record;
  final int frameIndex;

  /// Called with (rally index, winner) when the user picks a winner.
  final void Function(int rallyIndex, String winner)? onCorrect;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final theme = Theme.of(context);
    final score = record.scoreAt(frameIndex);
    final summary = record.summary;
    return SectionCard(
      title: 'Score and stats',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (score == null)
            Text('Enable the referee layer to keep score.', style: theme.textTheme.bodySmall)
          else ...[
            Semantics(
              label: 'Score: near ${score.near}, far ${score.far}',
              excludeSemantics: true,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _Side(label: 'Near', points: score.near, color: colors.near),
                  Text(':', style: theme.textTheme.headlineMedium),
                  _Side(label: 'Far', points: score.far, color: colors.far),
                ],
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            for (final rally in record.rallies)
              _RallyRow(
                rally: rally,
                current: record.rallyAt(frameIndex)?.index == rally.index,
                onCorrect: onCorrect == null || busy
                    ? null
                    : (winner) => onCorrect!(rally.index, winner),
              ),
            if (record.score!.corrections.isNotEmpty)
              Text(
                '${record.score!.corrections.length} correction(s) made',
                style: theme.textTheme.bodySmall,
              ),
          ],
          if (summary != null && summary.strokeCounts.isNotEmpty) ...[
            const Divider(height: 24),
            for (final e in summary.strokeCounts.entries)
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

class _RallyRow extends StatelessWidget {
  const _RallyRow({required this.rally, required this.current, this.onCorrect});

  final Rally rally;
  final bool current;
  final ValueChanged<String>? onCorrect;

  @override
  Widget build(BuildContext context) {
    final landing = rally.landing;
    final call = landing == null
        ? 'no landing call'
        : '${landing.inCourt ? 'in' : 'out'}${landing.uncertain ? ' ?' : ''}';
    final needsConfirm = rally.winner == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Rally ${rally.index + 1} · ${rally.strokeCount} strokes · $call',
              style: TextStyle(fontWeight: current ? FontWeight.w600 : null),
            ),
          ),
          if (needsConfirm)
            Tooltip(
              message: 'Uncertain call: pick the winner',
              child: Icon(Icons.help_outline, size: 18, color: Theme.of(context).colorScheme.error),
            ),
          for (final side in ['near', 'far'])
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ChoiceChip(
                label: Text(side == 'near' ? 'Near' : 'Far'),
                selected: rally.winner == side,
                tooltip: 'Rally ${rally.index + 1} won by the $side player',
                onSelected: onCorrect == null || rally.winner == side
                    ? null
                    : (_) => onCorrect!(side),
              ),
            ),
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
