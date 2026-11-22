import '../../../shared/widgets/courtside_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/clip_record.dart';
import '../../../shared/disclaimers.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../core/theme/tokens.dart';

/// Seek requests from other screens (chat citations) to a job's results player.
final seekRequestProvider = StateProvider.family<Moment?, String>((ref, jobId) => null);

/// F21 / C6: the top 3 things to fix, each with the moments that show it (tap to seek),
/// the other notes, and the way into the coach chat.
class SessionSummary extends StatefulWidget {
  const SessionSummary({
    super.key,
    required this.record,
    required this.onSeek,
    this.videoAvailable = true,
    this.doubles = false,
    this.onAskCoach,
    this.chatAvailable = false,
    this.onGoalChanged,
    this.report,
  });

  final ClipRecord record;
  final ValueChanged<Moment> onSeek;
  final bool videoAvailable;
  final bool doubles;
  final VoidCallback? onAskCoach;
  final bool chatAvailable;
  final void Function(PracticeGoal, bool)? onGoalChanged;

  /// The AI coaching report card (D42), shown above the way into the chat.
  final Widget? report;

  @override
  State<SessionSummary> createState() => _SessionSummaryState();
}

class _SessionSummaryState extends State<SessionSummary> {
  String? _player;

  bool _matches(String player) => _player == null || _player == player || _player == sideOf(player);

  Widget _goalCard(PracticeGoal goal) {
    final frame = goal.frame;
    final time = goal.timeS;
    final canSeek =
        widget.videoAvailable &&
        frame != null &&
        frame >= 0 &&
        frame < widget.record.numFrames &&
        time != null &&
        time.isFinite &&
        time >= 0;
    return PracticeGoalCard(
      goal: goal,
      onSeek: canSeek ? widget.onSeek : null,
      onComplete: widget.onGoalChanged == null ? null : (done) => widget.onGoalChanged!(goal, done),
    );
  }

  Widget _noteTile(SessionNote note, {int? rank}) => _NoteTile(
    note: note,
    rank: rank,
    onSeek: widget.videoAvailable ? widget.onSeek : null,
    moments: note.moments
        .where((moment) => moment.frame >= 0 && moment.frame < widget.record.numFrames)
        .toList(),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = widget.record;
    final coaching = record.coaching;
    final notes = coaching?.notes ?? const <SessionNote>[];
    final attributed = notes.where((note) => note.player != null && _matches(note.player!));
    final top =
        (_player == null
                ? coaching?.topFixes.where((note) => note.player != null) ?? const <SessionNote>[]
                : Coaching.rankedFixes(attributed))
            .take(3)
            .toList();
    final others = attributed.where((note) => !top.contains(note)).toList();
    final generalNotes = notes.where((note) => note.player == null).toList();
    final goals = [
      for (final goal in record.practiceGoals)
        if (goal.player case final String player when _matches(player)) goal,
    ];
    final generalGoals = record.practiceGoals.where((goal) => goal.player == null).toList();
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
          if (record.summary != null && record.summary!.strokeCounts.isNotEmpty) ...[
            Text('Session stroke totals', style: theme.textTheme.titleSmall),
            Wrap(
              spacing: 8,
              children: [
                for (final item in record.summary!.strokeCounts.entries)
                  Chip(label: Text('${kStrokeLabels[item.key] ?? item.key}: ${item.value}')),
              ],
            ),
          ],
          if (notes.any((note) => note.player != null) ||
              record.practiceGoals.any((goal) => goal.player != null))
            CoachPlayerFilter(
              player: _player,
              doubles: widget.doubles || record.isDoubles,
              onChanged: (player) => setState(() => _player = player),
            ),
          for (final goal in goals) _goalCard(goal),
          if (top.isEmpty)
            Text(
              _player != null
                  ? 'No repeated pattern was identified for ${playerLabel(_player!)}.'
                  : coaching == null
                  ? 'Session notes appear once strokes are classified.'
                  : 'Not enough evidence of a repeated pattern in this session.',
              style: theme.textTheme.bodyMedium,
            )
          else ...[
            Text('Top things to fix', style: theme.textTheme.titleSmall),
            for (final (i, note) in top.indexed) _noteTile(note, rank: i + 1),
          ],
          if (others.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('More player notes (${others.length})'),
              children: [for (final note in others) _noteTile(note)],
            ),
          if (generalNotes.isNotEmpty || generalGoals.isNotEmpty) ...[
            Text('Session-wide notes and goals', style: theme.textTheme.titleSmall),
            for (final goal in generalGoals) _goalCard(goal),
            for (final note in generalNotes) _noteTile(note),
          ],
          ?widget.report,
          const SizedBox(height: Spacing.md),
          FilledButton.icon(
            onPressed: widget.chatAvailable ? widget.onAskCoach : null,
            icon: const Icon(Icons.forum_outlined),
            label: const Text('Ask your coach'),
          ),
          if (!widget.chatAvailable)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(
                'Coach chat is off on this server (no Gemini or Claude API key). Notes still work.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: Spacing.sm),
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
  const _NoteTile({required this.note, required this.onSeek, required this.moments, this.rank});

  final SessionNote note;
  final ValueChanged<Moment>? onSeek;
  final List<Moment> moments;
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
              padding: const EdgeInsets.only(right: Spacing.md),
              child: CircleAvatar(radius: 14, child: Text('$rank')),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(note.text),
                if (onSeek case final seek? when moments.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  MomentChips(moments: moments, onSeek: seek),
                ],
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
