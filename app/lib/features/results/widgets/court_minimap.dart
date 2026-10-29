import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/section_card.dart';

/// Singles court size in meters (backend/shuttlesense/schema.py COURT_SIZE_M).
const double kCourtWidthM = 5.18;
const double kCourtLengthM = 13.40;

/// F10: top-down court with both players and the shuttle for the current frame.
class CourtMinimap extends StatelessWidget {
  const CourtMinimap({super.key, required this.frame, required this.calibrated});

  final FrameInfo? frame;
  final bool calibrated;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Court',
      child: calibrated
          ? AspectRatio(
              aspectRatio: kCourtWidthM / kCourtLengthM,
              child: CustomPaint(
                painter: CourtPainter(
                  frame: frame,
                  lines: Theme.of(context).colorScheme.outline,
                  surface: Theme.of(context).colorScheme.surfaceContainerHighest,
                  players: PlayerColors.of(context),
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
    required this.frame,
    required this.lines,
    required this.surface,
    required this.players,
  });

  final FrameInfo? frame;
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
    const shortServiceM = 1.98;
    for (final dy in [-shortServiceM * sy, shortServiceM * sy]) {
      canvas.drawLine(Offset(0, netY + dy), Offset(size.width, netY + dy), line);
    }
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, netY - shortServiceM * sy),
      line,
    );
    canvas.drawLine(
      Offset(size.width / 2, netY + shortServiceM * sy),
      Offset(size.width / 2, size.height),
      line,
    );

    final f = frame;
    if (f == null) return;
    if (f.nearPos != null) {
      canvas.drawCircle(toCanvas(f.nearPos!), 7, Paint()..color = players.near);
    }
    if (f.farPos != null) {
      canvas.drawCircle(toCanvas(f.farPos!), 7, Paint()..color = players.far);
    }
    if (f.shuttlePos != null) {
      canvas.drawCircle(toCanvas(f.shuttlePos!), 4, Paint()..color = players.shuttle);
    }
  }

  @override
  bool shouldRepaint(CourtPainter old) => old.frame != frame || old.lines != lines;
}
