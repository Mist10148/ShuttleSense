import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/shuttle_speed.dart';

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
const double kHeatCellM = 0.25;

/// Heatmap kernel width in meters at the near and the far baseline (D44, same as
/// backend/shuttlesense/analytics/heatmap.py): wider far from the camera, where a pixel
/// covers more court and the foot point is less certain.
const double kHeatSigmaNearM = 0.30;
const double kHeatSigmaFarM = 0.45;

/// Frames between heatmap rebuilds while a live session grows.
const int kHeatRebuildFrames = 30;

/// Run-off drawn around the court lines, in meters. A player or a landing outside the
/// lines stays inside the picture; anything further out is shown at the edge of this band.
const double kRunOffM = 1.5;

/// The court's long side is never drawn shorter than this, however little room there is.
const double kMinCourtLength = 220;

/// Height the card needs besides the court itself: padding, the title row and the gap.
const double _kCardChrome = 100;

/// Width / height of the picture: the court, the doubles alleys and the run-off band.
double courtViewAspect({required bool doubles}) =>
    (kCourtWidthM + (doubles ? 2 * kDoublesAlleyM : 0) + 2 * kRunOffM) /
    (kCourtLengthM + 2 * kRunOffM);

/// The height the minimap card may take, set by the layout that holds it (the visible
/// height of the side panel or tab). The court is a tall shape in a short panel: sized by
/// width alone it runs far below the fold, so the card scales the court down to fit here.
class CourtMaxHeight extends InheritedWidget {
  const CourtMaxHeight({super.key, required this.height, required super.child});

  final double height;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CourtMaxHeight>()?.height;

  @override
  bool updateShouldNotify(CourtMaxHeight old) => old.height != height;
}

/// Size of the court picture for a card [maxWidth] wide that may be [maxHeight] tall, and
/// whether the court lies on its side (near end on the left).
///
/// Upright, the court is as wide as the card when that fits, else as tall as the room
/// allows. Where the room is short and wide (the tab under the video on a phone) an upright
/// court would be a sliver, so it is laid on its side when that draws it larger.
(Size, bool) courtViewLayout(double maxWidth, double maxHeight, {required bool doubles}) {
  final aspect = courtViewAspect(doubles: doubles); // short side / long side
  final room = maxHeight - _kCardChrome;
  Size fit(double shortMax, double longMax) {
    var long = shortMax / aspect;
    if (long > longMax) long = longMax < kMinCourtLength ? kMinCourtLength : longMax;
    if (long * aspect > shortMax) long = shortMax / aspect;
    return Size(long * aspect, long);
  }

  final upright = fit(maxWidth, room);
  // On its side the long side runs across the card, which bounds it without a minimum.
  final across = fit(room < 0 ? 0 : room, maxWidth).flipped;
  return across.width * across.height > upright.width * upright.height
      ? (across, true)
      : (upright, false);
}

/// F10: top-down court with both players, the shuttle trail, the current rally's hits and
/// the landing of every line call so far (F20: green in, red out, amber still uncertain).
/// The Heatmap toggle (T5.5) shades where each player stood over the whole clip.
class CourtMinimap extends StatefulWidget {
  const CourtMinimap({
    super.key,
    required this.record,
    required this.frameIndex,
    this.reviewCall,
    this.live = false,
    this.rallyStart,
    this.doubles,
  });

  final ClipRecord record;
  final int frameIndex;
  final LineCall? reviewCall;

  /// A live session: its record only holds closed rallies, so the open rally's start comes
  /// from the session ([rallyStart], null between rallies: no hit marks).
  final bool live;
  final int? rallyStart;

  /// Known from the job or session; null: worked out from the record.
  final bool? doubles;

  @override
  State<CourtMinimap> createState() => _CourtMinimapState();
}

class _CourtMinimapState extends State<CourtMinimap> {
  var _heatmap = false;
  HeatGrid? _heat;
  (Object, int, int)? _heatKey;

  /// Built once per clip, and during a live session again every [kHeatRebuildFrames]
  /// frames (the live record is a new object on every event, and positions never change
  /// after the fact, so rebuilding on each one would cost a pass over every frame).
  HeatGrid _heatGrid() {
    final record = widget.record;
    final key = (
      widget.live ? record.clipId : record,
      record.frames.length ~/ kHeatRebuildFrames,
      record.rallies.length,
    );
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
    final doubles = widget.doubles ?? record.isDoubles;
    final heat = calibrated && _heatmap ? _heatGrid() : null;
    return SectionCard(
      title: 'Court',
      trailing: calibrated
          ? FilterChip(
              label: const Text('Heatmap'),
              tooltip: doubles
                  ? 'Show time spent by each pair during play'
                  : 'Show time spent by each player during play',
              selected: _heatmap,
              onSelected: (on) => setState(() => _heatmap = on),
            )
          : null,
      child: calibrated
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: [
                    minimapLabel(record, frameIndex, doubles: doubles),
                    if (widget.reviewCall case final call?)
                      'Highlighted landing for rally ${call.rallyIndex + 1}.',
                    ?heat?.describe(),
                  ].join(' '),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // The whole court has to be on screen at once: the layout says how tall
                      // the card may be, else most of the window is assumed.
                      final room =
                          CourtMaxHeight.maybeOf(context) ??
                          MediaQuery.sizeOf(context).height * 0.7;
                      final (size, onSide) = courtViewLayout(
                        constraints.maxWidth,
                        room,
                        doubles: doubles,
                      );
                      final scheme = Theme.of(context).colorScheme;
                      return Center(
                        child: SizedBox.fromSize(
                          size: size,
                          // Nothing is painted outside the picture (heat cells and marks used
                          // to spill over the card and the panels around it).
                          child: ClipRect(
                            child: CustomPaint(
                              painter: CourtPainter.fromRecord(
                                record,
                                frameIndex,
                                lines: scheme.outline,
                                surface: scheme.surfaceContainerHighest,
                                runOff: scheme.surfaceContainerLow,
                                players: PlayerColors.of(context),
                                status: StatusColors.of(context),
                                heat: heat,
                                reviewLanding: widget.reviewCall?.landing,
                                live: widget.live,
                                rallyStart: widget.rallyStart,
                                doubles: doubles,
                                onSide: onSide,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const ShuttleSpeedLegend(),
              ],
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
String minimapLabel(ClipRecord record, int frameIndex, {bool? doubles}) {
  final f = record.frame(frameIndex);
  if (f == null) return 'Top-down court, no positions for this moment';
  String at(String who, CourtPoint? p) => p == null
      ? '$who not seen'
      : '$who at ${p.x.toStringAsFixed(1)} m across, ${p.y.toStringAsFixed(1)} m up the court';
  final isDoubles = doubles ?? record.isDoubles;
  final shuttle = shuttleOverCourt(record, frameIndex, doubles: isDoubles);
  final location = at('Shuttle', shuttle?.$1);
  final description = shuttle == null
      ? location
      : '$location (${shuttle.$2 ? 'rally estimate' : 'camera projection'})';
  if (isDoubles) {
    return 'Top-down doubles court. ${at('Near player 1', f.nearPos)}. '
        '${at('Near player 2', f.near2Pos)}. ${at('Far player 1', f.farPos)}. '
        '${at('Far player 2', f.far2Pos)}. $description.';
  }
  return 'Top-down court. ${at('Near player', f.nearPos)}. ${at('Far player', f.farPos)}. '
      '$description.';
}

/// Where the shuttle is over the court at [frameIndex], and whether that is worked out
/// from the rally (true) or only the camera's view pushed onto the floor (false).
///
/// The court positions come from a floor-plane mapping, which is right for feet and for a
/// landing but not for a shuttle in the air: seen from behind the court, a high shuttle
/// lands far beyond where it really is. Between two hits the shuttle travels from the
/// player who hit it to the player who hits it next (or to where it landed), so its place
/// over the court is taken along that line by time. Before the first hit of a rally, after
/// the last one without a landing, and in a live rally whose next hit is not known yet,
/// only the floor mapping is left.
(CourtPoint, bool)? shuttleOverCourt(ClipRecord record, int frameIndex, {bool? doubles}) {
  // Only frames where the shuttle was seen are drawn: the line says where it is, not
  // whether it was tracked.
  final raw = record.frame(frameIndex)?.shuttlePos;
  if (raw == null) return null;
  (CourtPoint, bool)? fallback() => (raw, false);

  Hit? before, after;
  for (final h in record.hits) {
    if (h.frame <= frameIndex) {
      before = h;
    } else {
      after = h;
      break;
    }
  }
  if (before == null) return fallback();
  final isDoubles = doubles ?? record.isDoubles;
  // A doubles hit with no credited partner has no single place on the court.
  CourtPoint? standing(Hit h) =>
      isDoubles && h.hitter == null ? null : record.frame(h.frame)?.positionOf(h.who);
  final from = standing(before);
  if (from == null) return fallback();

  CourtPoint? to;
  int? toFrame;
  final sameRally =
      after != null &&
      (before.rallyIndex == null || after.rallyIndex == null
          ? after.frame - before.frame <= 3 * record.fps
          : before.rallyIndex == after.rallyIndex);
  if (sameRally) {
    to = standing(after);
    toFrame = after.frame;
  } else {
    // The rally's last hit: the shuttle goes to where it was called in or out.
    for (final c in record.lineCalls) {
      if (c.frame > before.frame && (after == null || c.frame < after.frame)) {
        to = c.landing;
        toFrame = c.frame;
        break;
      }
    }
  }
  if (to == null || toFrame == null || toFrame <= before.frame) return fallback();
  if (frameIndex > toFrame) return fallback();
  final t = (frameIndex - before.frame) / (toFrame - before.frame);
  return ((x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), true);
}

/// How long each side stood in each [kHeatCellM] cell of the court (and up to 2 m beyond
/// the lines, as far as the backend keeps a position), over the rallies of the clip.
///
/// Same method as the backend's heatmap.json (D44): each frame in play adds 1 / fps
/// seconds at a player's position, spread by a Gaussian in meters that widens away from
/// the camera. Positions pinned to the 2 m clamp edge are left out: the player was
/// somewhere beyond it, not there.
class HeatGrid {
  HeatGrid._(
    this.near,
    this.far,
    this.nearMax,
    this.farMax,
    this.nearShade,
    this.farShade, {
    this.doubles = false,
  });

  static const double margin = 2.0;
  static final int cols = ((kCourtWidthM + 2 * margin) / kHeatCellM).ceil();
  static final int rows = ((kCourtLengthM + 2 * margin) / kHeatCellM).ceil();

  /// Kernel width in meters at court depth [y].
  static double sigmaAt(double y) =>
      kHeatSigmaNearM + (kHeatSigmaFarM - kHeatSigmaNearM) * (y / kCourtLengthM).clamp(0.0, 1.0);

  /// Whether [p] sits on the edge the backend clamps positions to (2 m around the court).
  static bool atClampEdge(CourtPoint p) {
    const tol = 1e-3;
    return p.x <= -margin + tol ||
        p.x >= kCourtWidthM + margin - tol ||
        p.y <= -margin + tol ||
        p.y >= kCourtLengthM + margin - tol;
  }

  factory HeatGrid.fromRecord(ClipRecord record) {
    final near = List.filled(cols * rows, 0.0), far = List.filled(cols * rows, 0.0);
    final seconds = 1 / (record.fps > 0 ? record.fps : 30.0);
    // Cell centres in court meters.
    double cx(int c) => (c + 0.5) * kHeatCellM - margin;
    double cy(int r) => (r + 0.5) * kHeatCellM - margin;
    void add(List<double> grid, CourtPoint? p) {
      if (p == null || atClampEdge(p)) return;
      final sigma = sigmaAt(p.y);
      final reach = (3 * sigma / kHeatCellM).ceil();
      final c0 = ((p.x + margin) / kHeatCellM).floor();
      final r0 = ((p.y + margin) / kHeatCellM).floor();
      final wx = <int, double>{}, wy = <int, double>{};
      for (var c = c0 - reach; c <= c0 + reach; c++) {
        if (c < 0 || c >= cols) continue;
        final d = (cx(c) - p.x) / sigma;
        wx[c] = math.exp(-0.5 * d * d);
      }
      for (var r = r0 - reach; r <= r0 + reach; r++) {
        if (r < 0 || r >= rows) continue;
        final d = (cy(r) - p.y) / sigma;
        wy[r] = math.exp(-0.5 * d * d);
      }
      final total =
          wx.values.fold<double>(0, (a, b) => a + b) * wy.values.fold<double>(0, (a, b) => a + b);
      if (total <= 0) return;
      // Normalised over the cells it reaches, so every frame adds exactly its time.
      final k = seconds / total;
      for (final MapEntry(key: r, value: vy) in wy.entries) {
        for (final MapEntry(key: c, value: vx) in wx.entries) {
          grid[r * cols + c] += k * vx * vy;
        }
      }
    }

    // Only frames in play count: between rallies a player waits or fetches the shuttle,
    // and those minutes in one spot would outweigh every rally. A record without rallies
    // (referee off, or a live session before its first rally closes) counts every frame.
    final rallies = record.rallies;
    var rally = 0;
    for (final f in record.frames) {
      if (rallies.isNotEmpty) {
        while (rally < rallies.length && rallies[rally].endFrame < f.frame) {
          rally++;
        }
        if (rally >= rallies.length) break;
        if (f.frame < rallies[rally].startFrame) continue;
      }
      // A side's heat covers both partners in doubles.
      add(near, f.nearPos);
      add(near, f.near2Pos);
      add(far, f.farPos);
      add(far, f.far2Pos);
    }
    double max(List<double> g) => g.fold(0.0, (a, b) => a > b ? a : b);
    return HeatGrid._(
      near,
      far,
      max(near),
      max(far),
      shade(near),
      shade(far),
      doubles: record.isDoubles,
    );
  }

  /// Seconds per cell, row-major from the near-left corner (court y grows away).
  final List<double> near, far;
  final double nearMax, farMax;

  /// How strongly each cell is shaded, 0 to 1 (see [shade]).
  final List<double> nearShade, farShade;

  /// Doubles: each grid covers both partners of a side.
  final bool doubles;

  /// Seconds per cell scaled to 0..1.
  ///
  /// The scale tops out at the 95th percentile of the cells holding a noticeable share
  /// (over 1% of the busiest), so the single busiest cell does not leave the rest of the
  /// court too faint to read, and never below 60% of the busiest cell, so a clip with few
  /// cells keeps its gradient.
  static List<double> shade(List<double> seconds) {
    final out = List.filled(seconds.length, 0.0);
    final peak = seconds.fold(0.0, (a, b) => a > b ? a : b);
    if (peak <= 0) return out;
    final seen = [
      for (final v in seconds)
        if (v > peak * 0.01) v,
    ]..sort();
    final top = math.max(seen[((seen.length - 1) * 0.95).round()], peak * 0.6);
    for (var i = 0; i < out.length; i++) {
      out[i] = (seconds[i] / top).clamp(0.0, 1.0);
    }
    return out;
  }

  /// Near-left corner of a cell in court meters.
  static CourtPoint cellOrigin(int index) =>
      (x: (index % cols) * kHeatCellM - margin, y: (index ~/ cols) * kHeatCellM - margin);

  /// Where each player stood most, for screen readers.
  String describe() {
    String where(String who, List<double> grid, double max) {
      if (max <= 0) return '$who not seen';
      final o = cellOrigin(grid.indexOf(max));
      final x = (o.x + kHeatCellM / 2).toStringAsFixed(1);
      final y = (o.y + kHeatCellM / 2).toStringAsFixed(1);
      return '$who mostly at $x m across, $y m up the court';
    }

    final who = doubles ? 'pair' : 'player';
    return 'Heatmap: ${where('near $who', near, nearMax)}; '
        '${where('far $who', far, farMax)}.';
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
    Color? runOff,
    required this.players,
    this.status = StatusColors.light,
    this.heat,
    this.doubles = false,
    this.onSide = false,
  }) : runOff = runOff ?? surface;

  /// Collects the current frame, the trail and the hitters' positions in this rally.
  factory CourtPainter.fromRecord(
    ClipRecord record,
    int frameIndex, {
    required Color lines,
    required Color surface,
    Color? runOff,
    required PlayerColors players,
    StatusColors status = StatusColors.light,
    HeatGrid? heat,
    CourtPoint? reviewLanding,
    bool live = false,
    int? rallyStart,
    bool? doubles,
    bool onSide = false,
  }) {
    // Worked out once: on a long singles record isDoubles scans every frame.
    final isDoubles = doubles ?? record.isDoubles;
    final trail = <(int, CourtPoint, bool, double?, bool)>[];
    final first = math.max(0, frameIndex - kTrailLength + 1);
    final boundaries = {
      for (final rally in record.rallies)
        if (rally.startFrame <= frameIndex && rally.endFrame >= first - 1) ...[
          rally.startFrame,
          rally.endFrame + 1,
        ],
    };
    for (var i = first; i <= frameIndex; i++) {
      final point = shuttleOverCourt(record, i, doubles: isDoubles);
      if (point == null) continue;
      final frame = record.frame(i);
      final connected =
          trail.isNotEmpty &&
          trail.last.$1 == i - 1 &&
          trail.last.$3 == point.$2 &&
          !boundaries.contains(i) &&
          frame?.rallyState == record.frame(i - 1)?.rallyState;
      trail.add((i, point.$1, point.$2, frame?.shuttleSpeedKmh, connected));
    }
    // Marks belong to the rally on screen. Live, that is the open rally (none between
    // rallies). Offline between rallies: the hits since the last rally ended.
    int? start;
    if (live) {
      start = rallyStart;
    } else {
      start = record.rallyAt(frameIndex)?.startFrame;
      if (start == null) {
        start = 0;
        for (final r in record.rallies) {
          if (r.endFrame >= frameIndex) break;
          start = r.endFrame + 1;
        }
      }
    }
    // Each hit is marked where the player who made it stood (the partner, in doubles). A
    // doubles hit with no known partner has no single spot: marking it at partner 1 would
    // credit the hit to them.
    final marks = <(String, CourtPoint)>[
      if (start != null)
        for (final h in record.hits)
          if (h.frame >= start && h.frame <= frameIndex && !(isDoubles && h.hitter == null))
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
      runOff: runOff,
      players: players,
      status: status,
      heat: heat,
      doubles: isDoubles,
      onSide: onSide,
    );
  }

  final int frameIndex;
  final FrameInfo? frame;

  /// Shuttle positions, oldest first, each with whether it is placed along the rally's
  /// flight line (true) or only mapped onto the floor (false; see [shuttleOverCourt]).
  final List<(int, CourtPoint, bool, double?, bool)> trail;
  final List<(String, CourtPoint)> hitMarks;

  /// (landing point, called in, waiting for review), oldest first.
  final List<(CourtPoint, bool, bool)> landings;
  final CourtPoint? reviewLanding;
  final Color lines;

  /// The court inside the lines, and the run-off band around it.
  final Color surface;
  final Color runOff;
  final StatusColors status;
  final PlayerColors players;

  /// Shaded under everything else when the heatmap is on.
  final HeatGrid? heat;

  /// Draws the doubles alleys and long service lines, and both partners.
  final bool doubles;

  /// The court lies on its side: near end on the left, far end on the right.
  final bool onSide;

  @override
  void paint(Canvas canvas, Size box) {
    canvas.save();
    canvas.clipRect(Offset.zero & box);
    // Everything below is drawn upright; on its side the picture is turned a quarter so
    // that the near baseline (the bottom edge) becomes the left edge.
    var size = box;
    if (onSide) {
      canvas.translate(box.width, 0);
      canvas.rotate(math.pi / 2);
      size = box.flipped;
    }
    final alley = doubles ? kDoublesAlleyM : 0.0;
    final sx = size.width / (kCourtWidthM + 2 * alley + 2 * kRunOffM);
    final sy = size.height / (kCourtLengthM + 2 * kRunOffM);
    // Court y grows toward the far baseline; draw the near side at the bottom. x is from the
    // singles sideline, so the doubles alley lies left of 0 and the run-off left of that.
    Offset toCanvas(CourtPoint p) =>
        Offset((p.x + alley + kRunOffM) * sx, size.height - (p.y + kRunOffM) * sy);
    // A mark outside the picture is shown at its edge, a little inside so it stays whole.
    const inset = 0.15;
    Offset mark(CourtPoint p) => toCanvas((
      x: p.x.clamp(-alley - kRunOffM + inset, kCourtWidthM + alley + kRunOffM - inset),
      y: p.y.clamp(-kRunOffM + inset, kCourtLengthM + kRunOffM - inset),
    ));
    Offset? playerMark(CourtPoint p) {
      final o = toCanvas(p);
      return (Offset.zero & size).contains(o) ? o : null;
    }

    // The outer lines of the court (doubles sidelines when there are alleys).
    final court = Rect.fromPoints(
      toCanvas((x: -alley, y: kCourtLengthM)),
      toCanvas((x: kCourtWidthM + alley, y: 0)),
    );
    final left = toCanvas((x: 0, y: 0)).dx, right = toCanvas((x: kCourtWidthM, y: 0)).dx;

    canvas.drawRect(Offset.zero & size, Paint()..color = runOff);
    canvas.drawRect(court, Paint()..color = surface);
    final h = heat;
    if (h != null) {
      for (final (shade, color) in [(h.nearShade, players.near), (h.farShade, players.far)]) {
        for (var i = 0; i < shade.length; i++) {
          // Below this a cell only holds what spread over from a neighbour's edge.
          if (shade[i] < 0.04) continue;
          final o = HeatGrid.cellOrigin(i);
          canvas.drawRect(
            toCanvas((x: o.x, y: o.y + kHeatCellM)) & Size(kHeatCellM * sx, kHeatCellM * sy),
            Paint()..color = color.withValues(alpha: 0.08 + 0.55 * shade[i]),
          );
        }
      }
    }
    final line = Paint()
      ..color = lines
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRect(court, line);
    if (doubles) {
      // Singles sidelines inside the doubles outline, and the doubles long service lines.
      canvas.drawLine(Offset(left, court.top), Offset(left, court.bottom), line);
      canvas.drawLine(Offset(right, court.top), Offset(right, court.bottom), line);
      for (final y in [
        court.top + kDoublesLongServiceM * sy,
        court.bottom - kDoublesLongServiceM * sy,
      ]) {
        canvas.drawLine(Offset(court.left, y), Offset(court.right, y), line);
      }
    }
    final netY = court.center.dy;
    canvas.drawLine(Offset(court.left, netY), Offset(court.right, netY), line..strokeWidth = 2.5);
    line.strokeWidth = 1;
    for (final dy in [-kShortServiceFromNetM * sy, kShortServiceFromNetM * sy]) {
      canvas.drawLine(Offset(court.left, netY + dy), Offset(court.right, netY + dy), line);
    }
    final centre = (left + right) / 2;
    canvas.drawLine(
      Offset(centre, court.top),
      Offset(centre, netY - kShortServiceFromNetM * sy),
      line,
    );
    canvas.drawLine(
      Offset(centre, netY + kShortServiceFromNetM * sy),
      Offset(centre, court.bottom),
      line,
    );

    for (var i = 0; i < landings.length; i++) {
      final (p, isIn, review) = landings[i];
      final color = status.forCall(isIn: isIn, review: review);
      final latest = i == landings.length - 1;
      canvas.drawCircle(
        mark(p),
        latest ? 6 : 4,
        Paint()
          ..color = color.withValues(alpha: latest ? 1 : 0.6)
          ..style = latest ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    for (final (who, p) in hitMarks) {
      final c = players.forPlayer(who);
      final cross = Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      final o = playerMark(p);
      if (o == null) continue;
      canvas.drawLine(o - const Offset(4, 4), o + const Offset(4, 4), cross);
      canvas.drawLine(o - const Offset(4, -4), o + const Offset(4, -4), cross);
    }
    final f = frame;
    for (final (p, color) in [(f?.nearPos, players.near), (f?.farPos, players.far)]) {
      final o = p == null ? null : playerMark(p);
      if (o != null) canvas.drawCircle(o, 7, Paint()..color = color);
    }
    // Doubles partners: their own colour, with a ring so they differ by shape too.
    for (final (p, color) in [(f?.near2Pos, players.near2), (f?.far2Pos, players.far2)]) {
      final o = p == null ? null : playerMark(p);
      if (o == null) continue;
      canvas.drawCircle(o, 6, Paint()..color = color);
      canvas.drawCircle(
        o,
        8,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }
    if (reviewLanding case final landing?) {
      // An outside landing stays visible at the edge of the run-off.
      final o = mark(landing);
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
    paintShuttleTrail(
      canvas,
      [
        for (final (_, point, placed, speed, connected) in trail)
          (point: mark(point), speed: speed, approximate: !placed, connected: connected),
      ],
      hasCurrent: trail.isNotEmpty && trail.last.$1 == frameIndex,
      ageAt: (i) => (frameIndex - trail[i].$1) / kTrailLength,
    );
    canvas.restore();
  }

  /// Only repaint when playback moves to another frame, the record or the theme changes.
  /// The trail and the marks are compared by content: in a live session the frame index can
  /// stay put while a new hit or a corrected position arrives.
  @override
  bool shouldRepaint(CourtPainter old) =>
      old.frameIndex != frameIndex ||
      old.reviewLanding != reviewLanding ||
      old.frame != frame ||
      old.lines != lines ||
      old.surface != surface ||
      old.runOff != runOff ||
      old.players != players ||
      old.status != status ||
      old.heat != heat ||
      old.doubles != doubles ||
      old.onSide != onSide ||
      !listEquals(old.trail, trail) ||
      !listEquals(old.hitMarks, hitMarks) ||
      !listEquals(old.landings, landings);
}
