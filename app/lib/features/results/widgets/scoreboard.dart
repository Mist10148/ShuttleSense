import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/section_card.dart';

/// F14/F16: assisted scoreboard at the current playback position, with per-rally winner
/// chips to correct the referee layer's calls, and the match state (D21): games, who
/// serves from which court, game and match point, interval and change of ends. With
/// [onAward] and [onUndo] the referee can add a point the system missed and take back the
/// newest score change.
class Scoreboard extends StatelessWidget {
  const Scoreboard({
    super.key,
    required this.record,
    required this.frameIndex,
    this.onCorrect,
    this.onAward,
    this.onUndo,
    this.onClearLast,
    this.busy = false,
    this.live = false,
    this.showHistory = true,
  });

  final ClipRecord record;
  final int frameIndex;

  /// Called with (rally index, winner) when the user picks a winner; winner null clears it.
  final void Function(int rallyIndex, String? winner)? onCorrect;

  /// A point for a rally the system missed, for the given side.
  final ValueChanged<String>? onAward;

  /// Take back the newest correction or award.
  final VoidCallback? onUndo;
  final VoidCallback? onClearLast;
  final bool busy;

  /// A live session: the score is always the current one.
  final bool live;
  final bool showHistory;

  /// Whether the playback position is past the last rally, where the match state (server,
  /// game point, ...) describes what is on screen.
  bool get _atEnd => live || record.rallies.isEmpty || frameIndex >= record.rallies.last.endFrame;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final theme = Theme.of(context);
    final total = record.score;
    final atEnd = _atEnd;
    final score = atEnd ? total : record.scoreAt(frameIndex);
    final summary = record.summary;
    final server = atEnd ? total?.server : null;
    return SectionCard(
      title: 'Score and stats',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (score == null || total == null)
            Text('Enable the referee layer to keep score.', style: theme.textTheme.bodySmall)
          else ...[
            if (total.bestOf > 1)
              Text(
                'Game ${total.game} of ${total.bestOf} · games '
                '${total.gamesWon.near}–${total.gamesWon.far}',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge,
              ),
            Semantics(
              label: [
                'Score: near ${score.near}, far ${score.far}',
                if (server != null)
                  '${server == 'near' ? 'Near' : 'Far'} serves from the '
                      '${total.serviceCourt} court',
              ].join('. '),
              excludeSemantics: true,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _Side(
                    label: 'Near',
                    points: score.near,
                    color: colors.near,
                    serving: server == 'near',
                  ),
                  Text(':', style: theme.textTheme.headlineMedium),
                  _Side(
                    label: 'Far',
                    points: score.far,
                    color: colors.far,
                    serving: server == 'far',
                  ),
                ],
              ),
            ),
            if (atEnd) _MatchState(score: total),
            if (onAward != null || onUndo != null) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final side in ['near', 'far'])
                    OutlinedButton.icon(
                      onPressed: onAward == null || busy || total.matchOver
                          ? null
                          : () => onAward!(side),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(side == 'near' ? 'Point Near' : 'Point Far'),
                    ),
                  TextButton.icon(
                    onPressed: onUndo == null || busy || total.corrections.isEmpty ? null : onUndo,
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('Undo'),
                  ),
                  if (onClearLast != null)
                    TextButton(
                      onPressed: busy ? null : onClearLast,
                      child: const Text('Clear last winner'),
                    ),
                ],
              ),
            ],
            if (busy) const LinearProgressIndicator(),
            if (showHistory) ...[
              const SizedBox(height: 8),
              RallyHistory(
                record: record,
                frameIndex: frameIndex,
                onCorrect: busy ? null : onCorrect,
              ),
            ],
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

class RallyHistory extends StatelessWidget {
  const RallyHistory({super.key, required this.record, required this.frameIndex, this.onCorrect});

  final ClipRecord record;
  final int frameIndex;
  final void Function(int rallyIndex, String? winner)? onCorrect;

  @override
  Widget build(BuildContext context) {
    final current = record.rallyAt(frameIndex)?.index;
    final corrections = record.score?.corrections ?? const <ScoreCorrection>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final rally in record.rallies)
          _RallyRow(
            rally: rally,
            showGame: (record.score?.bestOf ?? 1) > 1,
            current: current == rally.index,
            onCorrect: onCorrect == null ? null : (winner) => onCorrect!(rally.index, winner),
          ),
        if (corrections.isNotEmpty)
          Text(_changes(corrections), style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  static String _changes(List<ScoreCorrection> corrections) {
    final awards = corrections.where((c) => c.isAward).length;
    final fixes = corrections.length - awards;
    return [
      if (fixes > 0) '$fixes correction(s)',
      if (awards > 0) '$awards point(s) awarded',
    ].join(' · ');
  }
}

/// Who serves, game or match point, interval, change of ends, or the match result.
class _MatchState extends StatelessWidget {
  const _MatchState({required this.score});

  final Score score;

  static String _name(String side) => side == 'near' ? 'Near' : 'Far';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final winner = score.matchWinner;
    final chips = <Widget>[
      if (winner != null)
        Chip(
          avatar: const Icon(Icons.emoji_events_outlined, size: 16),
          label: Text(score.bestOf > 1 ? 'Match won by ${_name(winner)}' : '${_name(winner)} wins'),
        )
      else ...[
        if (score.server != null)
          Chip(
            avatar: const Icon(Icons.sports_tennis, size: 16),
            label: Text('${_name(score.server!)} serves · ${score.serviceCourt} court'),
          ),
        for (final side in score.matchPoint)
          Chip(
            backgroundColor: scheme.tertiaryContainer,
            label: Text('Match point ${_name(side)}'),
          ),
        for (final side in score.gamePoint)
          if (!score.matchPoint.contains(side))
            Chip(
              backgroundColor: scheme.secondaryContainer,
              label: Text('Game point ${_name(side)}'),
            ),
      ],
    ];
    final notice = winner != null
        ? null
        : score.changeEnds
        ? 'Change ends'
        : score.interval
        ? 'Interval: up to 60 s'
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (chips.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: chips,
            ),
          ),
        if (notice != null)
          Semantics(
            liveRegion: true,
            child: Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                score.changeEnds && score.interval ? 'Interval: change ends' : notice,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onPrimaryContainer, fontWeight: FontWeight.w600),
              ),
            ),
          ),
      ],
    );
  }
}

class _RallyRow extends StatelessWidget {
  const _RallyRow({
    required this.rally,
    required this.current,
    this.showGame = false,
    this.onCorrect,
  });

  final Rally rally;
  final bool current;
  final bool showGame;
  final ValueChanged<String?>? onCorrect;

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
              '${showGame ? 'G${rally.game} · ' : ''}Rally ${rally.index + 1} · '
              '${rally.strokeCount} strokes · $call',
              style: TextStyle(fontWeight: current ? FontWeight.w600 : null),
            ),
          ),
          if (needsConfirm)
            Tooltip(
              message: 'Undecided: pick the winner',
              child: Icon(Icons.help_outline, size: 18, color: Theme.of(context).colorScheme.error),
            ),
          for (final side in ['near', 'far'])
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ChoiceChip(
                label: Text(side == 'near' ? 'Near' : 'Far'),
                selected: rally.winner == side,
                tooltip: rally.winner == side
                    ? 'Rally ${rally.index + 1} won by the $side player; tap to clear'
                    : 'Rally ${rally.index + 1} won by the $side player',
                // Tapping the chosen winner again makes the rally undecided (not counted).
                onSelected: onCorrect == null
                    ? null
                    : (_) => onCorrect!(rally.winner == side ? null : side),
              ),
            ),
        ],
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({
    required this.label,
    required this.points,
    required this.color,
    this.serving = false,
  });

  final String label;
  final int points;
  final Color color;
  final bool serving;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (serving) ...[Icon(Icons.circle, size: 10, color: color), const SizedBox(width: 4)],
            Text(
              label,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Text('$points', style: Theme.of(context).textTheme.displaySmall),
      ],
    );
  }
}
