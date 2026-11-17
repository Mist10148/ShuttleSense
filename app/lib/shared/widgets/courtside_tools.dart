import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/clip_record.dart';

class CoachPlayerFilter extends StatelessWidget {
  const CoachPlayerFilter({
    super.key,
    required this.player,
    required this.doubles,
    required this.onChanged,
  });

  final String? player;
  final bool doubles;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    return Wrap(
      spacing: Spacing.sm,
      children: [
        for (final value in [
          null,
          'near',
          'far',
          if (doubles) ...['near_1', 'near_2', 'far_1', 'far_2'],
        ])
          ChoiceChip(
            avatar: value == null
                ? null
                : Icon(Icons.circle, size: 12, color: colors.forPlayer(value)),
            showCheckmark: value == null,
            label: Text(value == null ? 'Both' : playerLabel(value)),
            selected: player == value,
            onSelected: (_) => onChanged(value),
          ),
      ],
    );
  }
}

class DecisionHistory extends StatefulWidget {
  const DecisionHistory({super.key, required this.record, this.onSeek});
  final ClipRecord record;
  final ValueChanged<Moment>? onSeek;

  @override
  State<DecisionHistory> createState() => _DecisionHistoryState();
}

class _DecisionHistoryState extends State<DecisionHistory> {
  int? _game;
  bool _undoneOnly = false;

  @override
  Widget build(BuildContext context) {
    final entries = widget.record.decisionLog;
    final games = entries.map((entry) => entry.game).toSet().toList()..sort();
    final game = games.contains(_game) ? _game : null;
    final visible = entries.reversed
        .where((entry) => (game == null || entry.game == game) && (!_undoneOnly || entry.undone))
        .toList();
    return ExpansionTile(
      title: Text('Decision history (${entries.length})'),
      children: [
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(Spacing.lg),
            child: Text(
              'New referee decisions appear here. Older records may have no audit history.',
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<int>(
                  value: game ?? 0,
                  items: [
                    const DropdownMenuItem(value: 0, child: Text('All games')),
                    for (final game in games)
                      DropdownMenuItem(value: game, child: Text('Game $game')),
                  ],
                  onChanged: (game) => setState(() => _game = game == 0 ? null : game),
                ),
                FilterChip(
                  label: const Text('Undone only'),
                  selected: _undoneOnly,
                  onSelected: (selected) => setState(() => _undoneOnly = selected),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: Text(
              visible.isEmpty
                  ? 'No matching decisions'
                  : '${visible.length} of ${entries.length} decisions',
            ),
          ),
          for (final entry in visible) _entry(entry),
        ],
      ],
    );
  }

  Widget _entry(DecisionEntry entry) {
    final frame = entry.frame;
    final record = widget.record;
    final onSeek = widget.onSeek;
    final seek =
        onSeek != null && record.fps > 0 && frame != null && frame >= 0 && frame < record.numFrames;
    return ListTile(
      leading: Icon(entry.undone ? Icons.undo : Icons.sports),
      title: Text('${entry.detail}${entry.undone ? ' · Undone' : ''}'),
      subtitle: Text(
        'Game ${entry.game}${entry.rally == null ? '' : ' · Rally ${entry.rally! + 1}'}'
        ' · ${entry.near}–${entry.far}\n${entry.at.toLocal()}',
      ),
      trailing: seek ? const Icon(Icons.play_arrow) : null,
      onTap: seek ? () => onSeek(Moment(frame: frame, timeS: frame / record.fps)) : null,
    );
  }
}

class IntervalPanel extends StatefulWidget {
  const IntervalPanel({
    super.key,
    required this.interval,
    required this.onAction,
    this.elapsedClock,
  });
  final IntervalState interval;
  final Stopwatch? elapsedClock;
  final ValueChanged<String>? onAction;
  @override
  State<IntervalPanel> createState() => _IntervalPanelState();
}

class _IntervalPanelState extends State<IntervalPanel> {
  Timer? _ticker;
  @override
  void initState() {
    super.initState();
    widget.elapsedClock?.start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(IntervalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.interval, widget.interval)) widget.elapsedClock?.reset();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.elapsedClock?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock = widget.interval;
    // The time since the state arrived, not since this widget was built: switching role
    // or layout builds a new panel, which must not start the countdown again.
    final injected = widget.elapsedClock;
    final left = injected == null || clock.status != 'running'
        ? clock.remainingNow
        : clock.remaining - injected.elapsedMilliseconds / 1000;
    final remaining = max(0, left).ceil();
    final finished = clock.status == 'complete' || (clock.status == 'running' && remaining == 0);
    final status = finished
        ? 'Interval complete'
        : clock.status == 'ended'
        ? 'Interval ended'
        : 'Interval · $remaining s';
    final actions = <String, String>{
      if (clock.status == 'ready') 'start': 'Start',
      if (clock.status == 'running' && !finished) 'pause': 'Pause',
      if (clock.status == 'paused') 'resume': 'Resume',
      'reset': 'Reset',
      if (clock.status != 'ended') 'end': 'End',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(status, style: Theme.of(context).textTheme.headlineSmall),
            const Text('Timer only. Play and scoring remain under referee control.'),
            Wrap(
              spacing: 8,
              children: [
                for (final action in actions.entries)
                  TextButton(
                    onPressed: widget.onAction == null ? null : () => widget.onAction!(action.key),
                    child: Text(action.value),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<PracticeGoal?> editPracticeGoal(
  BuildContext context, {
  String? player,
  PracticeGoal? current,
}) async {
  var text = current?.text ?? '';
  return showDialog<PracticeGoal>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text('Practice goal · ${player == null ? 'Both' : playerLabel(player)}'),
        content: TextFormField(
          initialValue: text,
          autofocus: true,
          maxLength: 240,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'What will you practise?',
            helperText: 'Personal goal; not a measured finding.',
          ),
          onChanged: (value) => update(() => text = value),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, PracticeGoal(text: text.trim(), player: player)),
            child: const Text('Save goal'),
          ),
        ],
      ),
    ),
  );
}

class PracticeGoalCard extends StatelessWidget {
  const PracticeGoalCard({
    super.key,
    required this.goal,
    this.onComplete,
    this.onEdit,
    this.onSeek,
  });
  final PracticeGoal goal;
  final ValueChanged<bool>? onComplete;
  final VoidCallback? onEdit;
  final ValueChanged<Moment>? onSeek;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${goal.source == 'cue' ? 'Pinned practice cue' : 'Personal practice goal'} · ${goal.player == null ? 'Both' : playerLabel(goal.player!)}',
          ),
          Text(goal.text, style: Theme.of(context).textTheme.titleLarge),
          Text(goal.completed ? 'Completed · self-reported' : 'Active goal'),
          const Text('Not enough evidence to measure improvement on this goal.'),
          Wrap(
            spacing: 8,
            children: [
              if (onComplete != null)
                TextButton(
                  onPressed: () => onComplete!(!goal.completed),
                  child: Text(goal.completed ? 'Reopen goal' : 'Mark complete'),
                ),
              if (onEdit != null) TextButton(onPressed: onEdit, child: const Text('Edit goal')),
              if (onSeek != null && goal.frame != null)
                TextButton(
                  onPressed: () => onSeek!(Moment(frame: goal.frame!, timeS: goal.timeS ?? 0)),
                  child: const Text('View moment'),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}
