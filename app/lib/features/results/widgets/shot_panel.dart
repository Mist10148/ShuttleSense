import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/shuttle_speed.dart';
import '../../../shared/widgets/tactile.dart';
import 'stroke_timeline.dart' show formatClock;

/// What the shot panel shows at one frame: the current stroke, the shuttle speed, the rally
/// so far and the score. Pure, so it is easy to test.
class ShotReadout {
  const ShotReadout({
    required this.hit,
    required this.shotNumber,
    required this.speedKmh,
    required this.peakKmh,
    required this.rallyState,
    required this.strokes,
    required this.rallySeconds,
    required this.tempoSeconds,
    required this.score,
    required this.game,
  });

  /// The latest stroke at or before the frame, if any.
  final Hit? hit;

  /// The stroke's number within its rally (1 for the serve).
  final int shotNumber;

  /// The shuttle speed at the frame, else the current stroke's speed.
  final double? speedKmh;
  final double? peakKmh;
  final String? rallyState;
  final int strokes;

  /// Time from the rally's start to the frame (to its end once it is over).
  final double? rallySeconds;

  /// Average time between strokes so far in the rally.
  final double? tempoSeconds;
  final ScorePair? score;
  final int? game;

  factory ShotReadout.at(ClipRecord record, int frameIndex) {
    final fps = record.fps > 0 ? record.fps : 30.0;
    final frame = record.frame(frameIndex);
    final hit = record.hitAt(frameIndex);
    final rally = record.rallyAt(frameIndex) ?? (hit == null ? null : _rallyOf(record, hit));
    final start = rally?.startFrame ?? 0;
    final inRally = [
      for (final h in record.hits)
        if (h.frame >= start && h.frame <= frameIndex) h,
    ];
    double? tempo;
    if (inRally.length >= 2) {
      tempo = (inRally.last.timeS - inRally.first.timeS) / (inRally.length - 1);
    }
    double? rallySeconds;
    if (rally != null) {
      final end = frameIndex < rally.endFrame ? frameIndex : rally.endFrame;
      rallySeconds = (end - rally.startFrame).clamp(0, 1 << 30) / fps;
    }
    return ShotReadout(
      hit: hit,
      shotNumber: inRally.isEmpty ? 0 : inRally.length,
      speedKmh: frame?.shuttleSpeedKmh ?? hit?.speedKmh,
      peakKmh: record.summary?.peakSpeedKmh,
      rallyState: frame?.rallyState,
      strokes: record.strokesSoFar(frameIndex),
      rallySeconds: rallySeconds,
      tempoSeconds: tempo,
      score: record.scoreAt(frameIndex),
      game: record.score?.game,
    );
  }

  static Rally? _rallyOf(ClipRecord record, Hit hit) {
    for (final r in record.rallies) {
      if (r.index == hit.rallyIndex) return r;
    }
    return null;
  }
}

/// The speed bands used for the shuttle everywhere (shuttle_speed.dart), with labels.
const kSpeedBandLabels = ['Under 30 km/h', '30–60 km/h', '60–100 km/h', '100+ km/h'];

int? speedBand(double? kmh) {
  final color = shuttleSpeedColor(kmh);
  return color == null ? null : speedColors.indexOf(color);
}

/// The card at the top of the right column: the shot now (number, stroke, who, when), the
/// shuttle speed with its band, and the rally in four figures. Follows the playhead.
class ShotPanel extends StatelessWidget {
  const ShotPanel({super.key, required this.record, required this.frameIndex, this.dense});

  final ClipRecord record;
  final int frameIndex;

  /// Kept for callers; the card is one layout at every size.
  final bool? dense;

  @override
  Widget build(BuildContext context) {
    final r = ShotReadout.at(record, frameIndex);
    final p = AppPalette.of(context);
    final a = AnalysisColors.of(context);
    final text = Theme.of(context).textTheme;
    final hit = r.hit;
    final stroke = hit == null
        ? 'Ready'
        : (kStrokeLabels[hit.stroke] ?? 'Unclassified') + (hit.uncertain ? ' ?' : '');
    final state = switch (r.rallyState) {
      'in_play' => 'In play',
      'between_rallies' => 'Between rallies',
      _ => null,
    };
    final who = [
      if (hit != null) ...[
        playerLabel(hit.who),
        formatClock(hit.timeS),
        if (hit.confidence case final c?) '${(c * 100).round()}% sure',
      ] else
        'Play, or pick a stroke on the bar',
      ?state,
    ].join(' · ');
    final band = speedBand(r.speedKmh);
    final muted = text.bodySmall?.copyWith(color: p.text3);
    Widget figure(String label, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: muted),
          const SizedBox(height: 2),
          Text(value, style: kFigureStyle.copyWith(color: p.ink, fontSize: 20)),
        ],
      ),
    );
    final speed = r.speedKmh;
    final peak = r.peakKmh;
    final score = r.score;
    final rally = r.rallySeconds;
    final tempo = r.tempoSeconds;
    return Container(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.lg, Spacing.lg, Spacing.md),
      decoration: BoxDecoration(
        gradient: raisedGradient(TactileTokens.of(context)),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TactileTokens.of(context).rim),
        boxShadow: raisedShadows(TactileTokens.of(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: hit == null
                ? 'No stroke yet'
                : 'Shot ${r.shotNumber}: $stroke by the ${playerLabel(hit.who)} player '
                      'at ${formatClock(hit.timeS)}',
            excludeSemantics: true,
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  padding: const EdgeInsets.fromLTRB(7, 5, 7, 3),
                  decoration: BoxDecoration(
                    color: a.accent,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'SHOT',
                        style: TextStyle(
                          color: a.onAccent,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                      ),
                      Text(
                        r.shotNumber == 0 ? '–' : '${r.shotNumber}',
                        textAlign: TextAlign.end,
                        style: kFigureStyle.copyWith(
                          color: a.onAccent,
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          height: 0.85,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stroke.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: kFigureStyle.copyWith(
                          color: p.ink,
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: Spacing.xs),
                      Row(
                        children: [
                          if (hit != null) ...[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: PlayerColors.of(context).forPlayer(hit.who),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              who,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(color: p.text2, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      speed == null ? '–' : '${speed.round()}',
                      semanticsLabel: speed == null
                          ? 'Shuttle speed not measured here'
                          : 'Shuttle speed about ${speed.round()} kilometres per hour, estimated',
                      style: kFigureStyle.copyWith(
                        color: p.ink,
                        fontSize: 42,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      peak == null ? 'km/h · est.' : 'km/h · peak ${peak.round()}',
                      style: muted,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
          ExcludeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 0; i < speedColors.length; i++) ...[
                  if (i > 0) const SizedBox(width: Spacing.xs),
                  Expanded(
                    child: AnimatedContainer(
                      duration: Motion.fast,
                      height: i == band ? 7 : 4,
                      decoration: BoxDecoration(
                        color: i == band ? speedColors[i] : speedColors[i].withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Spacing.md),
          Divider(height: 1, color: p.hairline ?? p.surface2),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              figure('Rally', rally == null ? '–' : '${rally.toStringAsFixed(1)} s'),
              figure('Strokes', '${r.strokes}'),
              figure('Tempo', tempo == null ? '–' : '${tempo.toStringAsFixed(1)} s'),
              figure(
                score == null ? 'Score' : 'Game ${r.game ?? 1}',
                score == null ? '–' : '${score.near} : ${score.far}',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
