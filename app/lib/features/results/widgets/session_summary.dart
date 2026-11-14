import '../../../shared/widgets/courtside_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/clip_record.dart';
import '../../../shared/disclaimers.dart';
import '../../../shared/widgets/section_card.dart';

/// Seek requests from other screens (chat citations) to a job's results player.
final seekRequestProvider = StateProvider.family<Moment?, String>((ref, jobId) => null);

/// F21 / C6: the top 3 things to fix, each with the moments that show it (tap to seek),
/// the other notes, and the way into the coach chat.
class SessionSummary extends StatelessWidget {
  const SessionSummary({
    super.key,
    required this.record,
    required this.onSeek,
    this.onAskCoach,
    this.chatAvailable = false,
    this.onGoalChanged,
  });

  final ClipRecord record;
  final ValueChanged<Moment> onSeek;
  final VoidCallback? onAskCoach;
  final bool chatAvailable;
  final void Function(PracticeGoal, bool)? onGoalChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coaching = record.coaching;
    final top = coaching?.topFixes.take(3).toList() ?? const <SessionNote>[];
    final others = [
      for (final n in coaching?.notes ?? const <SessionNote>[])
        if (!top.contains(n)) n,
    ];
    return SectionCard(
      title: 'Coach',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Session recap', style: theme.textTheme.titleLarge),
          if (record.score?.matchWinner != null)
            Text('Match won by ${playerLabel(record.score!.matchWinner!)}'),
          if (record.score != null)
            Text('Games won: ${record.score!.gamesWon.near}–${record.score!.gamesWon.far}'),
          if (record.summary != null)
            Wrap(
              spacing: 8,
              children: [
                for (final item in record.summary!.strokeCounts.entries)
                  Chip(label: Text('${kStrokeLabels[item.key] ?? item.key}: ${item.value}')),
              ],
            ),
          for (final goal in record.practiceGoals)
            PracticeGoalCard(
              goal: goal,
              onSeek: onSeek,
              onComplete: onGoalChanged == null ? null : (done) => onGoalChanged!(goal, done),
            ),
          if (record.practiceGoals.isEmpty) const Text('No saved practice goals.'),
          if (top.isEmpty)
            Text(
              coaching == null
                  ? 'Session notes appear once strokes are classified.'
                  : 'Not enough evidence of a repeated pattern in this session.',
              style: theme.textTheme.bodyMedium,
            )
          else ...[
            Text('Top things to fix', style: theme.textTheme.titleSmall),
            for (final (i, note) in top.indexed) _NoteTile(rank: i + 1, note: note, onSeek: onSeek),
          ],
          if (others.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('All notes (${others.length + top.length})'),
              children: [for (final n in others) _NoteTile(note: n, onSeek: onSeek)],
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: chatAvailable ? onAskCoach : null,
            icon: const Icon(Icons.forum_outlined),
            label: const Text('Ask your coach'),
          ),
          if (!chatAvailable)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Coach chat is off on this server (no Claude API key). Notes still work.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            kCoachingDisclaimer,
            style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({required this.note, required this.onSeek, this.rank});

  final SessionNote note;
  final ValueChanged<Moment> onSeek;
  final int? rank;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rank != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: CircleAvatar(radius: 14, child: Text('$rank')),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(note.text),
                const SizedBox(height: 4),
                MomentChips(moments: note.moments, onSeek: onSeek),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tap-to-seek chips for timeline moments.
class MomentChips extends StatelessWidget {
  const MomentChips({super.key, required this.moments, required this.onSeek});

  final List<Moment> moments;
  final ValueChanged<Moment> onSeek;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 4,
    children: [
      for (final m in moments)
        ActionChip(
          avatar: const Icon(Icons.play_arrow, size: 16),
          label: Text(m.label),
          tooltip: 'Play from ${m.label}',
          onPressed: () => onSeek(m),
        ),
    ],
  );
}
