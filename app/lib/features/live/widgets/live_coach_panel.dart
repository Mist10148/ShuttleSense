import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/disclaimers.dart';
import '../../../shared/widgets/courtside_tools.dart';
import '../../../shared/widgets/section_card.dart';
import '../live_controller.dart';

typedef PracticeCue = ({String text, int rally});

/// Between-rally coaching (F21): what the last rally showed and the running top fixes,
/// from the server's `coaching` events. The next-rally cue is set large, to be read at
/// arm's length between rallies. Chat opens once the session is saved.
class LiveCoachPanel extends StatelessWidget {
  const LiveCoachPanel({
    super.key,
    required this.state,
    this.player,
    this.onPlayerChanged,
    this.practiceCue,
    this.onPracticeCueChanged,
    this.goalControls,
  });

  final LiveState state;

  /// The side to coach (near or far), or null for both.
  final String? player;
  final ValueChanged<String?>? onPlayerChanged;
  final PracticeCue? practiceCue;
  final ValueChanged<PracticeCue?>? onPracticeCueChanged;
  final Widget? goalControls;

  Widget _pinButton(String text, int rally) {
    final cue = (text: text, rally: rally);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: cue == practiceCue ? null : () => onPracticeCueChanged?.call(cue),
        icon: const Icon(Icons.push_pin_outlined),
        label: Text(cue == practiceCue ? 'Pinned' : 'Pin cue'),
      ),
    );
  }

  List<SessionNote> _topFixes(Coaching? coaching) {
    if (coaching == null) return const [];
    if (player == null) return coaching.topFixes.take(3).toList();
    // Doubles notes carry the partner (near_2), so match on the side. Formation notes have
    // no severity and are not faults; the server keeps them out of its top fixes too.
    final notes = coaching.notes.where(
      (note) =>
          note.player == null ||
          note.player == player ||
          (!player!.contains('_') && sideOf(note.player!) == player),
    );
    return Coaching.rankedFixes(notes).take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = PlayerColors.of(context);
    final last = state.lastRally;
    final nextCue = _nextCue(last);
    final top = _topFixes(state.coaching);
    final side = player == null ? '' : playerLabel(player!);
    return SectionCard(
      title: 'Between-rally coaching',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onPlayerChanged != null)
            CoachPlayerFilter(player: player, doubles: state.doubles, onChanged: onPlayerChanged!),
          if (practiceCue case final cue?) ...[
            const SizedBox(height: Spacing.sm),
            _Tinted(
              color: scheme.tertiaryContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Pinned practice cue · Rally ${cue.rally + 1}',
                    style: theme.textTheme.labelLarge?.copyWith(color: scheme.onTertiaryContainer),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    cue.text,
                    style: theme.textTheme.titleMedium?.copyWith(color: scheme.onTertiaryContainer),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => onPracticeCueChanged?.call(null),
                      child: const Text('Clear pin'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: Spacing.sm),
          Semantics(
            liveRegion: true,
            child: _Tinted(
              color: scheme.primaryContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Next rally',
                    style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    nextCue ??
                        (last == null
                            ? 'Notes appear here after each rally.'
                            : player == null
                            ? 'Waiting for enough footage to suggest a cue.'
                            : 'Waiting for enough footage to suggest a cue for $side.'),
                    style:
                        (nextCue == null
                                ? theme.textTheme.titleMedium
                                : theme.textTheme.headlineSmall)
                            ?.copyWith(color: scheme.onPrimaryContainer),
                  ),
                ],
              ),
            ),
          ),
          if (last != null && nextCue != null && onPracticeCueChanged != null)
            _pinButton(nextCue, last.index),
          if (goalControls case final goal?) ...[const SizedBox(height: Spacing.sm), goal],
          if (last != null) ...[
            const Divider(height: 20),
            Text('Last rally', style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.xs),
            Text(
              [
                'Rally ${last.index + 1}',
                '${last.strokes} strokes',
                if (last.durationS != null) '${last.durationS!.toStringAsFixed(1)} s',
                if (last.peakSpeedKmh != null) 'peak ${last.peakSpeedKmh!.round()} km/h (est.)',
                if (last.call != null) 'landed ${last.call}',
                if (last.winner != null) '${playerLabel(last.winner!)} won',
              ].join(' · '),
            ),
          ],
          if (top.isNotEmpty) ...[
            const Divider(height: 20),
            Text('Focus so far', style: theme.textTheme.titleSmall),
            for (final (i, note) in top.indexed)
              Padding(
                padding: const EdgeInsets.only(top: Spacing.sm),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // The colour of the player or partner the note is about.
                      Container(
                        width: 4,
                        decoration: BoxDecoration(
                          color: note.player == null
                              ? scheme.outline
                              : colors.forPlayer(note.player!),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text('${i + 1}. ${note.text}', style: theme.textTheme.bodyLarge),
                      ),
                    ],
                  ),
                ),
              ),
          ],
          if (state.rallies.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: Spacing.sm),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              title: const Text('Recent completed rallies'),
              children: [
                for (final rally in state.rallies.reversed.take(3))
                  Builder(builder: (context) => _recentRally(context, rally)),
              ],
            ),
          const SizedBox(height: Spacing.sm),
          Text(kCoachingDisclaimer, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _recentRally(BuildContext context, Rally rally) {
    final hits = state.hits.reversed
        .skipWhile((hit) => hit.frame > rally.endFrame)
        .takeWhile((hit) => hit.frame >= rally.startFrame);
    String? cue;
    for (final hit in hits) {
      if (player != null && hit.player != player && hit.who != player) continue;
      cue = _formatCue(hit.who, hit.stroke, hit.tip);
      if (cue != null) break;
    }
    final count = rally.strokeCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rally ${rally.index + 1} · $count ${count == 1 ? 'stroke' : 'strokes'}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (cue != null) ...[
            Text(cue),
            if (onPracticeCueChanged != null) _pinButton(cue, rally.index),
          ],
        ],
      ),
    );
  }

  String? _nextCue(RallySummary? rally) {
    if (rally == null) return null;
    for (final fault in rally.faults) {
      if (player != null && fault.player != player && _faultWho(fault) != player) continue;
      final cue = _formatCue(_faultWho(fault), fault.stroke, fault.tip);
      if (cue != null) return cue;
    }
    return null;
  }

  /// The doubles partner behind a fault when known (from the event, else from its hit),
  /// otherwise the side.
  String _faultWho(({int hitId, String player, String? hitter, String? stroke, String? tip}) f) {
    if (f.hitter != null) return f.hitter!;
    for (final hit in state.hits.reversed) {
      if (hit.id == f.hitId) return hit.who;
    }
    return f.player;
  }

  /// "Near 2, Smash: tip" for a side or a doubles partner.
  String? _formatCue(String who, String? stroke, String? tip) {
    if (tip == null || tip.trim().isEmpty) return null;
    final name = playerLabel(who);
    final label = stroke == null ? name : '$name, ${kStrokeLabels[stroke] ?? stroke}';
    return '$label: ${tip.trim()}';
  }
}

/// A filled, rounded block that sets a cue apart from the rest of the panel.
class _Tinted extends StatelessWidget {
  const _Tinted({required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(Spacing.md),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(Radii.md)),
    child: child,
  );
}
