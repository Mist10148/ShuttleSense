import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/tactile.dart';
import 'court_minimap.dart' show HeatGrid;

/// How far and how fast a player moved, from the court positions in the record.
///
/// Worked out once per record: per frame, the distance covered so far, the running speed
/// over the last half second, and the top running speed so far. A step faster than a person
/// can run (a tracking glitch) and positions on the 2 m clamp edge are left out.
class PlayerMovement {
  PlayerMovement._(this.distance, this.speed, this.top);

  /// Metres covered up to each frame.
  final List<double> distance;

  /// km/h over the half second up to each frame (null where the player was not seen).
  final List<double?> speed;

  /// Highest [speed] up to each frame.
  final List<double> top;

  static const double _maxRunMps = 8;
  static final _cache = Expando<Map<String, PlayerMovement>>();

  static PlayerMovement of(ClipRecord record, String side) =>
      (_cache[record] ??= {})[side] ??= _build(record, side);

  static PlayerMovement _build(ClipRecord record, String side) {
    final fps = record.fps > 0 ? record.fps : 30.0;
    final n = record.frames.length;
    CourtPoint? at(int i) {
      final f = record.frames[i];
      final p = switch (side) {
        'near_2' => f.near2Pos,
        'far_2' => f.far2Pos,
        'near' || 'near_1' => f.nearPos,
        _ => f.farPos,
      };
      return p == null || HeatGrid.atClampEdge(p) ? null : p;
    }

    final distance = List.filled(n, 0.0);
    final speed = List<double?>.filled(n, null);
    final top = List.filled(n, 0.0);
    final window = math.max(1, (fps / 2).round());
    CourtPoint? last;
    int? lastFrame;
    var total = 0.0, best = 0.0;
    for (var i = 0; i < n; i++) {
      final p = at(i);
      if (p != null && last != null && lastFrame != null) {
        final step = math.sqrt(math.pow(p.x - last.x, 2) + math.pow(p.y - last.y, 2));
        if (step <= _maxRunMps * (i - lastFrame) / fps) total += step;
      }
      if (p != null) {
        last = p;
        lastFrame = i;
      }
      distance[i] = total;
      if (p != null && i >= window && at(i - window) != null) {
        final kmh = (total - distance[i - window]) / (window / fps) * 3.6;
        speed[i] = kmh;
        best = math.max(best, kmh);
      }
      top[i] = best;
    }
    return PlayerMovement._(distance, speed, top);
  }
}

/// One card per player: distance moved, running speed now and the top running speed so far.
class PlayerCards extends StatelessWidget {
  const PlayerCards({super.key, required this.record, required this.frameIndex});

  final ClipRecord record;
  final int frameIndex;

  @override
  Widget build(BuildContext context) {
    if (record.frames.isEmpty || record.courtCorners == null) return const SizedBox.shrink();
    final i = frameIndex.clamp(0, record.frames.length - 1);
    final colors = PlayerColors.of(context);
    // Doubles: a card for each of the four players, partners side by side.
    final players = record.isDoubles
        ? [('near_1', 'Near 1'), ('near_2', 'Near 2'), ('far_1', 'Far 1'), ('far_2', 'Far 2')]
        : [('near', 'Near player'), ('far', 'Far player')];
    Widget card((String, String) p) => _Card(
      name: p.$2,
      color: colors.forPlayer(p.$1),
      movement: PlayerMovement.of(record, p.$1),
      index: i,
    );
    return Column(
      children: [
        for (var row = 0; row < players.length; row += 2) ...[
          if (row > 0) const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(child: card(players[row])),
              const SizedBox(width: Spacing.md),
              Expanded(child: card(players[row + 1])),
            ],
          ),
        ],
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.name,
    required this.color,
    required this.movement,
    required this.index,
  });

  final String name;
  final Color color;
  final PlayerMovement movement;
  final int index;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: p.text3, fontSize: 11);
    final speed = movement.speed[index];
    // The unit stays small beside the number, so a figure never wraps onto two lines.
    Widget figure(String label, String value, String unit) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: muted, maxLines: 1),
          Text.rich(
            TextSpan(
              text: value,
              children: [
                if (value != '–' && unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: TextStyle(fontSize: 11, color: p.text3, letterSpacing: 0),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.fade,
            softWrap: false,
            style: kFigureStyle.copyWith(color: p.ink, fontSize: 17),
          ),
        ],
      ),
    );
    return Semantics(
      label:
          '$name: moved ${movement.distance[index].toStringAsFixed(1)} metres, '
          'top run ${movement.top[index].toStringAsFixed(1)} kilometres per hour',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(Spacing.md + 2, Spacing.md, Spacing.md, Spacing.md),
        decoration: BoxDecoration(
          gradient: raisedGradient(TactileTokens.of(context)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: TactileTokens.of(context).rim),
          boxShadow: raisedShadows(TactileTokens.of(context), depth: 0.7),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: Spacing.sm),
                Text(name, style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                figure('Moved', movement.distance[index].toStringAsFixed(1), 'm'),
                figure('Run, km/h', speed == null ? '–' : speed.toStringAsFixed(1), ''),
                figure('Top, km/h', movement.top[index].toStringAsFixed(1), ''),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
