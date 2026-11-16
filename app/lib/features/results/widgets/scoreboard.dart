import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/game_service_prompt.dart';
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
    this.onSetService,
    this.onAwardReason,
    this.onLet,
    this.onConcede,
    this.onSwapEnds,
    this.doubles = false,
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

  /// Doubles (D23): name who serves and receives first in a later game.
  final void Function(int game, String serverId, String receiverId)? onSetService;

  /// Clip record 1.5 (D33): a point with its reason (`fault`, `service_fault`, ...), a let
  /// (the last rally is replayed) and a retirement ([onConcede] gets the side that wins).
  /// Null on older backends, so the decision menu is left out.
  final void Function(String side, String reason)? onAwardReason;
  final VoidCallback? onLet;
  final ValueChanged<String>? onConcede;

  /// Clip record 1.7: the players changed ends (early, late, or not when the rules said
  /// so). Null on older backends.
  final VoidCallback? onSwapEnds;

  /// A doubles job or session, known from its settings even before the record shows it.
  final bool doubles;
  final bool busy;

  /// A live session: the score is always the current one.
  final bool live;
  final bool showHistory;

  /// Whether the playback position is past the last rally, where the match state (server,
  /// game point, ...) describes what is on screen.
  bool get _atEnd => live || record.rallies.isEmpty || frameIndex >= record.rallies.last.endFrame;

  /// The game on screen: the rally at the playback position, else the last one before it.
  int _gameAt(Score total) {
    if (_atEnd) return total.game;
    Rally? shown = record.rallyAt(frameIndex);
    if (shown == null) {
      for (final r in record.rallies) {
        if (r.endFrame > frameIndex) break;
        shown = r;
      }
    }
    return shown?.game ?? total.firstGame;
  }

  /// Games each side had won before [game] started.
  ScorePair _gamesWonBefore(Score total, int game) {
    var near = total.startGames?.near ?? 0, far = total.startGames?.far ?? 0;
    for (var i = 0; i < total.games.length && total.firstGame + i < game; i++) {
      final g = total.games[i];
      if (g.near > g.far) {
        near++;
      } else {
        far++;
      }
    }
    return ScorePair(near: near, far: far);
  }

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final theme = Theme.of(context);
    final total = record.score;
    final atEnd = _atEnd;
    final score = atEnd ? total : record.scoreAt(frameIndex);
    final summary = record.summary;
    final server = atEnd ? total?.server : null;
    final doubles = this.doubles || record.isDoubles;
    final game = total == null ? 1 : _gameAt(total);
    // Near and far are the ends at the moment shown. The match totals are by the ends at
    // the end of the session, so they are turned when the players stood the other way.
    final swapped = total == null
        ? false
        : atEnd
        ? total.endsSwapped
        : record.endsSwappedAt(frameIndex);
    final turn = total != null && swapped != total.endsSwapped;
    ScorePair seen(ScorePair p) => turn ? ScorePair(near: p.far, far: p.near) : p;
    final won = total == null
        ? null
        : atEnd
        ? total.gamesWon
        : seen(_gamesWonBefore(total, game));
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
                'Game $game of ${total.bestOf} · games ${won!.near}–${won.far}',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge,
              ),
            // Finished games keep their final score once the board resets to 0–0.
            if (total.games.isNotEmpty)
              Text(
                [
                  for (var i = 0; i < total.games.length; i++)
                    'G${total.firstGame + i} ${seen(total.games[i]).near}–${seen(total.games[i]).far}',
                ].join(' · '),
                key: const Key('game-scores'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            if (swapped)
              Text(
                'Ends changed: Near and Far are the ends as they are now',
                key: const Key('ends-changed'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            Semantics(
              label: [
                'Score: near ${score.near}, far ${score.far}',
                if (server != null)
                  '${playerLabel(total.serverId ?? server)} serves from the '
                      '${total.serviceCourt} court'
                      '${total.receiverId == null ? '' : ' to ${playerLabel(total.receiverId!)}'}',
              ].join('. '),
              excludeSemantics: true,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  Expanded(
                    child: _Side(
                      label: 'Near',
                      points: score.near,
                      color: colors.near,
                      serving: server == 'near',
                      large: live,
                    ),
                  ),
                  Text(':', style: theme.textTheme.headlineMedium),
                  Expanded(
                    child: _Side(
                      label: 'Far',
                      points: score.far,
                      color: colors.far,
                      serving: server == 'far',
                      large: live,
                    ),
                  ),
                ],
              ),
            ),
            // Doubles: who serves and receives, named (Phase 9).
            if (server != null && total.serverId != null && total.receiverId != null)
              Text(
                '${playerLabel(total.serverId!)} serves to ${playerLabel(total.receiverId!)}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            if (atEnd) _MatchState(score: total),
            // Doubles: the game winners chose their server; ask so the order can go on.
            if (atEnd &&
                onSetService != null &&
                doubles &&
                !total.matchOver &&
                total.game >= 2 &&
                total.server != null &&
                total.serverId == null)
              GameServicePrompt(
                game: total.game,
                servingSide: total.server!,
                busy: busy,
                onSet: onSetService!,
              ),
            if (onAward != null || onUndo != null) ...[
              const SizedBox(height: 8),
              // One large button per side, in the side's colour, under its score.
              if (onAward != null)
                Row(
                  children: [
                    for (final side in ['near', 'far']) ...[
                      if (side == 'far') const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 56),
                            backgroundColor: colors.forSide(side).withValues(alpha: 0.16),
                            foregroundColor: theme.colorScheme.onSurface,
                          ),
                          onPressed: busy || total.matchOver ? null : () => onAward!(side),
                          icon: Icon(Icons.add, size: 20, color: colors.forSide(side)),
                          label: Text(side == 'near' ? 'Point Near' : 'Point Far'),
                        ),
                      ),
                    ],
                  ],
                ),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    // Undo also takes back a line-call override (D32), which is not in the
                    // corrections list, so it stays available whenever there is one.
                    onPressed:
                        onUndo == null ||
                            busy ||
                            (total.corrections.isEmpty && !record.lineCalls.any((c) => c.reviewed))
                        ? null
                        : onUndo,
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('Undo'),
                  ),
                  if (onClearLast != null)
                    TextButton(
                      onPressed: busy ? null : onClearLast,
                      child: const Text('Clear last winner'),
                    ),
                  if (onAwardReason != null ||
                      onLet != null ||
                      onConcede != null ||
                      onSwapEnds != null)
                    DecisionMenu(
                      enabled: !busy,
                      matchOver: total.matchOver,
                      onAwardReason: onAwardReason,
                      onLet: onLet,
                      onConcede: onConcede,
                      onSwapEnds: onSwapEnds,
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
                doubles: doubles,
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
  const RallyHistory({
    super.key,
    required this.record,
    required this.frameIndex,
    this.onCorrect,
    this.doubles,
  });

  final ClipRecord record;
  final int frameIndex;
  final void Function(int rallyIndex, String? winner)? onCorrect;

  /// Known from the job or session; null: worked out from the record (once, not per row).
  final bool? doubles;

  @override
  Widget build(BuildContext context) {
    final current = record.rallyAt(frameIndex)?.index;
    final corrections = record.score?.corrections ?? const <ScoreCorrection>[];
    final doubles = this.doubles ?? record.isDoubles;
    final showGame = (record.score?.bestOf ?? 1) > 1;
    // The newest winner correction per rally says whether a cleared rally was a let.
    final lets = <int>{};
    for (final c in corrections) {
      if (c.kind != 'winner') continue;
      if (c.isLet) {
        lets.add(c.rallyIndex);
      } else {
        lets.remove(c.rallyIndex);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final rally in record.rallies)
          _RallyRow(
            rally: rally,
            showGame: showGame,
            doubles: doubles,
            isLet: rally.winner == null && lets.contains(rally.index),
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
    final concessions = corrections.where((c) => c.isConcede).length;
    final ends = corrections.where((c) => c.isEnds).length;
    final fixes = corrections.length - awards - concessions - ends;
    return [
      if (fixes > 0) '$fixes correction(s)',
      if (awards > 0) '$awards point(s) awarded',
      if (concessions > 0) 'retired',
      if (ends > 0) '$ends change(s) of ends',
    ].join(' · ');
  }
}

/// Who serves, game or match point, interval, change of ends, or the match result.
class _MatchState extends StatelessWidget {
  const _MatchState({required this.score});

  final Score score;

  static String _name(String side) => playerLabel(side);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final winner = score.matchWinner;
    final chips = <Widget>[
      if (winner != null)
        Chip(
          avatar: const Icon(Icons.emoji_events_outlined, size: 16),
          label: Text(
            '${score.bestOf > 1 ? 'Match won by ${_name(winner)}' : '${_name(winner)} wins'}'
            '${score.conceded ? ' (retired)' : ''}',
          ),
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
        ? 'Interval: up to ${score.intervalSeconds ?? 60} s'
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
                score.changeEnds && score.interval
                    ? 'Interval${score.intervalSeconds == null ? '' : ' (${score.intervalSeconds} s)'}'
                          ': change ends'
                    : notice,
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
    this.doubles = false,
    this.isLet = false,
    this.onCorrect,
  });

  final Rally rally;
  final bool current;
  final bool showGame;
  final bool doubles;

  /// Cleared as a let: replayed, so nothing is left to decide.
  final bool isLet;
  final ValueChanged<String?>? onCorrect;

  @override
  Widget build(BuildContext context) {
    final landing = rally.landing;
    final call = landing == null
        ? 'no landing call'
        : '${landing.inCourt ? 'in' : 'out'}${landing.uncertain ? ' ?' : ''}';
    final needsConfirm = rally.winner == null && !isLet;
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
          if (isLet)
            const Tooltip(
              message: 'Let: the rally is replayed',
              child: Chip(label: Text('Let'), visualDensity: VisualDensity.compact),
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
                label: Text(playerLabel(side)),
                selected: rally.winner == side,
                tooltip: rally.winner == side
                    ? 'Rally ${rally.index + 1} won by the $side ${doubles ? 'pair' : 'player'}; '
                          'tap to clear'
                    : 'Rally ${rally.index + 1} won by the $side ${doubles ? 'pair' : 'player'}',
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
    this.large = false,
  });

  final String label;
  final int points;
  final Color color;
  final bool serving;

  /// Live: larger numerals, readable from across the court.
  final bool large;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Scales down rather than overflowing in a narrow column or at large text sizes.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (serving) ...[
                Icon(Icons.sports_tennis, size: 16, color: color),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(color: color, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '$points',
            style: large
                ? Theme.of(context).textTheme.displayLarge
                : Theme.of(context).textTheme.displaySmall,
          ),
        ),
      ],
    );
  }
}

/// Referee decisions beyond a plain point (clip record 1.5, D33): a fault or service fault
/// (the point goes to the other side), a let (the last rally is replayed) and a retirement.
class DecisionMenu extends StatelessWidget {
  const DecisionMenu({
    super.key,
    required this.enabled,
    required this.matchOver,
    this.onAwardReason,
    this.onLet,
    this.onConcede,
    this.onSwapEnds,
  });

  final bool enabled;
  final bool matchOver;
  final void Function(String side, String reason)? onAwardReason;
  final VoidCallback? onLet;
  final ValueChanged<String>? onConcede;
  final VoidCallback? onSwapEnds;

  static String _other(String side) => side == 'near' ? 'far' : 'near';

  Future<void> _retire(BuildContext context, String retiring) async {
    final winner = _other(retiring);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${playerLabel(retiring)} retires?'),
        content: Text(
          '${playerLabel(winner)} wins the match. Rallies after this do not count. '
          'Undo takes it back.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Retire')),
        ],
      ),
    );
    if (ok == true) onConcede?.call(winner);
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const Key('decision-menu'),
      tooltip: 'More referee decisions',
      enabled: enabled && !matchOver,
      onSelected: (action) {
        final [kind, side] = action.split(':');
        switch (kind) {
          case 'fault' || 'service_fault':
            onAwardReason?.call(_other(side), kind);
          case 'let':
            onLet?.call();
          case 'ends':
            onSwapEnds?.call();
          case 'retire':
            _retire(context, side);
        }
      },
      itemBuilder: (context) => [
        if (onAwardReason != null)
          for (final side in const ['near', 'far']) ...[
            PopupMenuItem(
              value: 'fault:$side',
              child: Text('Fault by ${playerLabel(side)} (point ${playerLabel(_other(side))})'),
            ),
            PopupMenuItem(
              value: 'service_fault:$side',
              child: Text(
                'Service fault by ${playerLabel(side)} (point ${playerLabel(_other(side))})',
              ),
            ),
          ],
        if (onLet != null)
          const PopupMenuItem(value: 'let:-', child: Text('Let: replay the last rally')),
        if (onSwapEnds != null)
          const PopupMenuItem(value: 'ends:-', child: Text('Players changed ends')),
        if (onConcede != null)
          for (final side in const ['near', 'far'])
            PopupMenuItem(value: 'retire:$side', child: Text('${playerLabel(side)} retires')),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [Icon(Icons.more_horiz, size: 18), SizedBox(width: 4), Text('More')],
        ),
      ),
    );
  }
}
