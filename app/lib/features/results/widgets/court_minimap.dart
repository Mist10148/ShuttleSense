import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/section_card.dart';

/// Singles court in meters, same lines as backend/shuttlesense/court/lines.py.
const double kCourtWidthM = 5.18;
const double kCourtLengthM = 13.40;
const double kShortServiceFromNetM = 1.98;

/// Shuttle positions kept in the fading trail.
const int kTrailLength = 15;

/// F10: top-down court with both players, the shuttle trail, the current rally's hits and
/// the landing of every line call so far (F20: green in, red out, amber still uncertain).
class CourtMinimap extends StatelessWidget {
  const CourtMinimap({super.key, required this.record, required this.frameIndex});

  final ClipRecord record;
  final int frameIndex;

  @override
  Widget build(BuildContext context) {
    final calibrated = record.courtCorners != null;
    return SectionCard(
      title: 'Court',
      child: calibrated
          ? Semantics(
              label: 'Top-down court with player and shuttle positions',
              child: AspectRatio(
                aspectRatio: kCourtWidthM / kCourtLengthM,
                child: CustomPaint(
                  painter: CourtPainter.fromRecord(
                    record,
                    frameIndex,
                    lines: Theme.of(context).colorScheme.outline,
                    surface: Theme.of(context).colorScheme.surfaceContainerHighest,
                    players: PlayerColors.of(context),
                  ),
                ),
              ),
            )
          : Text(
              'Calibrate the court when uploading to see player and shuttle positions.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
    );
  }
}

class CourtPainter extends CustomPainter {
  CourtPainter({
    required this.frameIndex,
    required this.frame,
    required this.trail,
    required this.hitMarks,
    this.landings = const [],
    required this.lines,
    required this.surface,
    required this.players,
  });

  /// Collects the current frame, the trail and the hitters' positions in this rally.
  factory CourtPainter.fromRecord(
    ClipRecord record,
    int frameIndex, {
    required Color lines,
    required Color surface,
    required PlayerColors players,
  }) {
    final trail = <CourtPoint>[
      for (var i = (frameIndex - kTrailLength + 1).clamp(0, frameIndex); i <= frameIndex; i++)
        ?record.frame(i)?.shuttlePos,
    ];
    final rally = record.rallyAt(frameIndex);
    final start = rally?.startFrame ?? 0;
    final marks = <(String, CourtPoint)>[
      for (final h in record.hits)
        if (h.frame >= start && h.frame <= frameIndex)
          if ((h.player == 'near' ? record.frame(h.frame)?.nearPos : record.frame(h.frame)?.farPos)
              case final p?)
            (h.player, p),
    ];
    final landings = [
      for (final c in record.lineCalls)
        if (c.frame <= frameIndex) (c.landing, c.isIn, c.needsReview),
    ];
    return CourtPainter(
      frameIndex: frameIndex,
      frame: record.frame(frameIndex),
      trail: trail,
      hitMarks: marks,
      landings: landings,
      lines: lines,
      surface: surface,
      players: players,
    );
  }

  final int frameIndex;
  final FrameInfo? frame;
  final List<CourtPoint> trail;
  final List<(String, CourtPoint)> hitMarks;

  /// (landing point, called in, waiting for review), oldest first.
  final List<(CourtPoint, bool, bool)> landings;
  final Color lines;
  final Color surface;
  final PlayerColors players;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / kCourtWidthM;
    final sy = size.height / kCourtLengthM;
    // Court y grows toward the far baseline; draw the near side at the bottom.
    Offset toCanvas(CourtPoint p) => Offset(p.x * sx, size.height - p.y * sy);

    canvas.drawRect(Offset.zero & size, Paint()..color = surface);
    final line = Paint()
      ..color = lines
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Offset.zero & size, line);
    final netY = size.height / 2;
    canvas.drawLine(Offset(0, netY), Offset(size.width, netY), line..strokeWidth = 2.5);
    line.strokeWidth = 1;
    for (final dy in [-kShortServiceFromNetM * sy, kShortServiceFromNetM * sy]) {
      canvas.drawLine(Offset(0, netY + dy), Offset(size.width, netY + dy), line);
    }
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, netY - kShortServiceFromNetM * sy),
      line,
    );
    canvas.drawLine(
      Offset(size.width / 2, netY + kShortServiceFromNetM * sy),
      Offset(size.width / 2, size.height),
      line,
    );

    for (var i = 0; i < landings.length; i++) {
      final (p, isIn, review) = landings[i];
      final color = review
          ? Colors.amber.shade700
          : isIn
          ? Colors.green.shade600
          : Colors.red.shade600;
      final latest = i == landings.length - 1;
      final o = toCanvas((
        x: p.x.clamp(-0.5, kCourtWidthM + 0.5),
        y: p.y.clamp(-0.5, kCourtLengthM + 0.5),
      ));
      canvas.drawCircle(
        o,
        latest ? 6 : 4,
        Paint()
          ..color = color.withValues(alpha: latest ? 1 : 0.6)
          ..style = latest ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    for (final (side, p) in hitMarks) {
      final c = side == 'near' ? players.near : players.far;
      final mark = Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      final o = toCanvas(p);
      canvas.drawLine(o - const Offset(4, 4), o + const Offset(4, 4), mark);
      canvas.drawLine(o - const Offset(4, -4), o + const Offset(4, -4), mark);
    }
    for (var i = 0; i < trail.length; i++) {
      final age = (trail.length - 1 - i) / kTrailLength; // 0 = newest
      canvas.drawCircle(
        toCanvas(trail[i]),
        4 - 2.5 * age,
        Paint()..color = players.shuttle.withValues(alpha: 1 - 0.85 * age),
      );
    }

    final f = frame;
    if (f == null) return;
    if (f.nearPos != null) {
      canvas.drawCircle(toCanvas(f.nearPos!), 7, Paint()..color = players.near);
    }
    if (f.farPos != null) {
      canvas.drawCircle(toCanvas(f.farPos!), 7, Paint()..color = players.far);
    }
  }

  /// Only repaint when playback moves to another frame, the record or the theme changes.
  @override
  bool shouldRepaint(CourtPainter old) =>
      old.frameIndex != frameIndex ||
      old.frame != frame ||
      old.lines != lines ||
      old.surface != surface ||
      old.players != players ||
      old.trail.length != trail.length ||
      old.hitMarks.length != hitMarks.length ||
      !listEquals(old.landings, landings);
}
