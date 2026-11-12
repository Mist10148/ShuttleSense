import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/section_card.dart';

/// Singles court in meters, same lines as backend/shuttlesense/court/lines.py.
const double kCourtWidthM = 5.18;
const double kCourtLengthM = 13.40;
const double kShortServiceFromNetM = 1.98;

/// Doubles lines (Phase 9): side alleys outside the singles sidelines, and the doubles
/// long service line inside each baseline.
const double kDoublesAlleyM = 0.46;
const double kDoublesLongServiceM = 0.76;

/// Shuttle positions kept in the fading trail.
const int kTrailLength = 15;

/// Side of a heatmap cell in meters.
const double kHeatCellM = 0.5;

/// Frames between heatmap rebuilds while a live session grows.
const int kHeatRebuildFrames = 30;

/// F10: top-down court with both players, the shuttle trail, the current rally's hits and
/// the landing of every line call so far (F20: green in, red out, amber still uncertain).
/// The Heatmap toggle (T5.5) shades where each player stood over the whole clip.
class CourtMinimap extends StatefulWidget {
  const CourtMinimap({super.key, required this.record, required this.frameIndex, this.reviewCall});

  final ClipRecord record;
  final int frameIndex;
  final LineCall? reviewCall;

  @override
  State<CourtMinimap> createState() => _CourtMinimapState();
}

class _CourtMinimapState extends State<CourtMinimap> {
  var _heatmap = false;
  HeatGrid? _heat;
  (String, int)? _heatKey;

  /// Built once per clip, and during a live session again every [kHeatRebuildFrames]
  /// frames (the live record is a new object on every event, and positions never change
  /// after the fact, so rebuilding on each one would cost a pass over every frame).
  HeatGrid _heatGrid() {
    final record = widget.record;
    final key = (record.clipId, record.frames.length ~/ kHeatRebuildFrames);
    if (_heat == null || key != _heatKey) {
      _heat = HeatGrid.fromRecord(record);
      _heatKey = key;
    }
    return _heat!;
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record, frameIndex = widget.frameIndex;
    final calibrated = record.courtCorners != null;
    final heat = calibrated && _heatmap ? _heatGrid() : null;
    return SectionCard(
      title: 'Court',
      trailing: calibrated
          ? FilterChip(
              label: const Text('Heatmap'),
              tooltip: 'Shade where each player stood over the whole clip',
              selected: _heatmap,
              onSelected: (on) => setState(() => _heatmap = on),
            )
          : null,
      child: calibrated
          ? Semantics(
              label: [
                minimapLabel(record, frameIndex),
                if (widget.reviewCall case final call?)
                  'Highlighted landing for rally ${call.rallyIndex + 1}.',
                ?heat?.describe(),
              ].join(' '),
              child: AspectRatio(
                aspectRatio:
                    (kCourtWidthM + (record.isDoubles ? 2 * kDoublesAlleyM : 0)) / kCourtLengthM,
                child: CustomPaint(
                  painter: CourtPainter.fromRecord(
                    record,
                    frameIndex,
                    lines: Theme.of(context).colorScheme.outline,
                    surface: Theme.of(context).colorScheme.surfaceContainerHighest,
                    players: PlayerColors.of(context),
                    status: StatusColors.of(context),
                    heat: heat,
                    reviewLanding: widget.reviewCall?.landing,
                  ),
                ),
              ),
            )
          : Text(
              record.mode == 'live'
                  ? 'Calibrate the court before going live to see player and shuttle positions.'
                  : 'Calibrate the court when uploading to see player and shuttle positions.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
    );
  }
}

/// What the minimap shows at [frameIndex], for screen readers (T4.11): each player's and the
/// shuttle's position in court meters (x across from the left sideline, y from the near
/// baseline).
String minimapLabel(ClipRecord record, int frameIndex) {
  final f = record.frame(frameIndex);
  if (f == null) return 'Top-down court, no positions for this moment';
  String at(String who, CourtPoint? p) => p == null
      ? '$who not seen'
      : '$who at ${p.x.toStringAsFixed(1)} m across, ${p.y.toStringAsFixed(1)} m up the court';
  if (record.isDoubles) {
    return 'Top-down doubles court. ${at('Near player 1', f.nearPos)}. '
        '${at('Near player 2', f.near2Pos)}. ${at('Far player 1', f.farPos)}. '
        '${at('Far player 2', f.far2Pos)}. ${at('Shuttle', f.shuttlePos)}.';
  }
  return 'Top-down court. ${at('Near player', f.nearPos)}. ${at('Far player', f.farPos)}. '
      '${at('Shuttle', f.shuttlePos)}.';
}

/// How often each player stood in each [kHeatCellM] cell of the court (and up to 1 m
/// beyond the lines), over every frame of the clip.
class HeatGrid {
  HeatGrid._(this.near, this.far, this.nearMax, this.farMax);

  static const double margin = 1.0;
  static final int cols = ((kCourtWidthM + 2 * margin + 2 * kDoublesAlleyM) / kHeatCellM).ceil();
  static final int rows = ((kCourtLengthM + 2 * margin) / kHeatCellM).ceil();

  factory HeatGrid.fromRecord(ClipRecord record) {
    final near = List.filled(cols * rows, 0), far = List.filled(cols * rows, 0);
    void add(List<int> grid, CourtPoint? p) {
      if (p == null) return;
      final c = ((p.x + margin + kDoublesAlleyM) / kHeatCellM).floor();
      final r = ((p.y + margin) / kHeatCellM).floor();
      if (c >= 0 && c < cols && r >= 0 && r < rows) grid[r * cols + c]++;
    }

    for (final f in record.frames) {
      // A side's heat covers both partners in doubles.
      add(near, f.nearPos);
      add(near, f.near2Pos);
      add(far, f.farPos);
      add(far, f.far2Pos);
    }
    int max(List<int> g) => g.fold(0, (a, b) => a > b ? a : b);
    return HeatGrid._(near, far, max(near), max(far));
  }

  /// Frame counts per cell, row-major from the near-left corner (court y grows away).
  final List<int> near, far;
  final int nearMax, farMax;

  /// Near-left corner of a cell in court meters.
  static CourtPoint cellOrigin(int index) => (
    x: (index % cols) * kHeatCellM - margin - kDoublesAlleyM,
    y: (index ~/ cols) * kHeatCellM - margin,
  );

  /// Where each player stood most, for screen readers.
  String describe() {
    String where(String who, List<int> grid, int max) {
      if (max == 0) return '$who not seen';
      final o = cellOrigin(grid.indexOf(max));
      final x = (o.x + kHeatCellM / 2).toStringAsFixed(1);
      final y = (o.y + kHeatCellM / 2).toStringAsFixed(1);
      return '$who mostly at $x m across, $y m up the court';
    }

    return 'Heatmap: ${where('near player', near, nearMax)}; '
        '${where('far player', far, farMax)}.';
  }
}

class CourtPainter extends CustomPainter {
  CourtPainter({
    required this.frameIndex,
    required this.frame,
    required this.trail,
    required this.hitMarks,
    this.landings = const [],
    this.reviewLanding,
    required this.lines,
    required this.surface,
    required this.players,
    this.status = StatusColors.light,
    this.heat,
    this.doubles = false,
  });

  /// Collects the current frame, the trail and the hitters' positions in this rally.
  factory CourtPainter.fromRecord(
    ClipRecord record,
    int frameIndex, {
    required Color lines,
    required Color surface,
    required PlayerColors players,
    StatusColors status = StatusColors.light,
    HeatGrid? heat,
    CourtPoint? reviewLanding,
  }) {
    final trail = <CourtPoint>[
      for (var i = (frameIndex - kTrailLength + 1).clamp(0, frameIndex); i <= frameIndex; i++)
        ?record.frame(i)?.shuttlePos,
    ];
    final rally = record.rallyAt(frameIndex);
    final start = rally?.startFrame ?? 0;
    // Each hit is marked where the player who made it stood (the partner, in doubles).
    final marks = <(String, CourtPoint)>[
      for (final h in record.hits)
        if (h.frame >= start && h.frame <= frameIndex)
          if (record.frame(h.frame)?.positionOf(h.who) case final p?) (h.who, p),
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
      reviewLanding: reviewLanding,
      lines: lines,
      surface: surface,
      players: players,
      status: status,
      heat: heat,
      doubles: record.isDoubles,
    );
  }

  final int frameIndex;
  final FrameInfo? frame;
  final List<CourtPoint> trail;
  final List<(String, CourtPoint)> hitMarks;

  /// (landing point, called in, waiting for review), oldest first.
  final List<(CourtPoint, bool, bool)> landings;
  final CourtPoint? reviewLanding;
  final Color lines;
  final Color surface;
  final StatusColors status;
  final PlayerColors players;

  /// Shaded under everything else when the heatmap is on.
  final HeatGrid? heat;

  /// Draws the doubles alleys and long service lines, and both partners.
  final bool doubles;

  @override
  void paint(Canvas canvas, Size size) {
    final alley = doubles ? kDoublesAlleyM : 0.0;
    final sx = size.width / (kCourtWidthM + 2 * alley);
    final sy = size.height / kCourtLengthM;
    // Court y grows toward the far baseline; draw the near side at the bottom. x is from the
    // singles sideline, so the doubles alley lies left of 0.
    Offset toCanvas(CourtPoint p) => Offset((p.x + alley) * sx, size.height - p.y * sy);
    final left = alley * sx, right = (alley + kCourtWidthM) * sx;

    canvas.drawRect(Offset.zero & size, Paint()..color = surface);
    final h = heat;
    if (h != null) {
      for (final (grid, max, color) in [
        (h.near, h.nearMax, players.near),
        (h.far, h.farMax, players.far),
      ]) {
        if (max == 0) continue;
        for (var i = 0; i < grid.length; i++) {
          if (grid[i] == 0) continue;
          final o = HeatGrid.cellOrigin(i);
          canvas.drawRect(
            toCanvas((x: o.x, y: o.y + kHeatCellM)) & Size(kHeatCellM * sx, kHeatCellM * sy),
            Paint()..color = color.withValues(alpha: 0.1 + 0.5 * grid[i] / max),
          );
        }
      }
    }
    final line = Paint()
      ..color = lines
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(Offset.zero & size, line);
    if (doubles) {
      // Singles sidelines inside the doubles outline, and the doubles long service lines.
      canvas.drawLine(Offset(left, 0), Offset(left, size.height), line);
      canvas.drawLine(Offset(right, 0), Offset(right, size.height), line);
      for (final y in [kDoublesLongServiceM * sy, size.height - kDoublesLongServiceM * sy]) {
        canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
      }
    }
    final netY = size.height / 2;
    canvas.drawLine(Offset(0, netY), Offset(size.width, netY), line..strokeWidth = 2.5);
    line.strokeWidth = 1;
    for (final dy in [-kShortServiceFromNetM * sy, kShortServiceFromNetM * sy]) {
      canvas.drawLine(Offset(0, netY + dy), Offset(size.width, netY + dy), line);
    }
    final centre = (left + right) / 2;
    canvas.drawLine(Offset(centre, 0), Offset(centre, netY - kShortServiceFromNetM * sy), line);
    canvas.drawLine(
      Offset(centre, netY + kShortServiceFromNetM * sy),
      Offset(centre, size.height),
      line,
    );

    for (var i = 0; i < landings.length; i++) {
      final (p, isIn, review) = landings[i];
      final color = status.forCall(isIn: isIn, review: review);
      final latest = i == landings.length - 1;
      final o = toCanvas((
        x: p.x.clamp(-0.5 - alley, kCourtWidthM + alley + 0.5),
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
    for (final (who, p) in hitMarks) {
      final c = players.forPlayer(who);
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
    if (trail.isNotEmpty) {
      // The light theme's yellow is faint on the court; a ring in the line colour keeps the
      // newest position visible (3:1, T4.11).
      canvas.drawCircle(
        toCanvas(trail.last),
        5,
        Paint()
          ..color = lines
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }

    final f = frame;
    if (f?.nearPos case final near?) {
      canvas.drawCircle(toCanvas(near), 7, Paint()..color = players.near);
    }
    if (f?.farPos case final far?) {
      canvas.drawCircle(toCanvas(far), 7, Paint()..color = players.far);
    }
    // Doubles partners: their own colour, with a ring so they differ by shape too.
    for (final (p, color) in [(f?.near2Pos, players.near2), (f?.far2Pos, players.far2)]) {
      if (p == null) continue;
      canvas.drawCircle(toCanvas(p), 6, Paint()..color = color);
      canvas.drawCircle(
        toCanvas(p),
        8,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    if (reviewLanding case final landing?) {
      final p = toCanvas(landing);
      // Keep an outside landing visible at the corresponding court edge.
      final o = Offset(p.dx.clamp(0, size.width).toDouble(), p.dy.clamp(0, size.height).toDouble());
      canvas.drawCircle(o, 9, Paint()..color = surface);
      canvas.drawCircle(o, 6, Paint()..color = status.uncertain);
      canvas.drawCircle(
        o,
        9,
        Paint()
          ..color = lines
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  /// Only repaint when playback moves to another frame, the record or the theme changes.
  @override
  bool shouldRepaint(CourtPainter old) =>
      old.frameIndex != frameIndex ||
      old.reviewLanding != reviewLanding ||
      old.frame != frame ||
      old.lines != lines ||
      old.surface != surface ||
      old.players != players ||
      old.status != status ||
      old.heat != heat ||
      old.doubles != doubles ||
      old.trail.length != trail.length ||
      old.hitMarks.length != hitMarks.length ||
      !listEquals(old.landings, landings);
}
