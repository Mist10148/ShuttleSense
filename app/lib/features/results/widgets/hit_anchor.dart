import 'package:flutter/painting.dart';

import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/hit_burst.dart';
import '../../watch/court_geometry.dart';
import 'court_minimap.dart';

/// Where [hit] happened in the video picture, as fractions of its width and height.
///
/// Prefer the measured video pixel. Older records may only have court positions, so
/// inverse-project a usable shuttle position or fall back to the hitter's side.
Offset? hitAnchor(ClipRecord record, Hit hit) {
  final frame = record.frame(hit.frame);
  if (frame == null || record.width <= 0 || record.height <= 0) return null;
  if (frame.shuttlePixel case (x: final x, y: final y)) {
    final at = hitBurstPicturePoint(x, y, record.width, record.height);
    if (at != null) return at;
  }
  final slot = switch (hit.who) {
    'near_1' => 'near',
    'far_1' => 'far',
    final slot => slot,
  };
  final hitter = frame.playerVideoAnchors[slot];
  final racketArea = hitter == null
      ? null
      : hitBurstPicturePoint(hitter.x, hitter.y, record.width, record.height);
  final corners = record.courtCorners;
  if (corners == null || corners.length != 4) return racketArea;
  final projection = CourtProjection.fromCorners(corners);
  if (projection == null) return racketArea;
  Offset? toPicture(CourtPoint p, {double raise = 0}) {
    final px = projection.point(p.x / kCourtWidthM, p.y / kCourtLengthM);
    if (px == null) return null;
    final at = Offset(px.x / record.width, px.y / record.height - raise);
    final inside = at.dx >= 0 && at.dx <= 1 && at.dy >= -raise && at.dy <= 1;
    return inside ? Offset(at.dx, at.dy.clamp(0.0, 1.0)) : null;
  }

  // The backend keeps the shuttle within 1 m of the court: at that limit the position is
  // no longer the shuttle's own.
  const limit = 0.98;
  final s = frame.shuttlePos;
  if (s != null &&
      s.x > -limit &&
      s.x < kCourtWidthM + limit &&
      s.y > -limit &&
      s.y < kCourtLengthM + limit) {
    if (toPicture(s) case final at?) return at;
  }
  if (racketArea != null) return racketArea;
  final feet = frame.positionOf(hit.who);
  if (feet == null) return null;
  // A player's racket is above the feet by roughly a quarter of the picture at the near
  // end and much less at the far end, where players are small.
  return toPicture(feet, raise: hit.player == 'near' ? 0.22 : 0.09);
}

HitBurstEvent hitBurstEvent(ClipRecord record, Hit hit) => HitBurstEvent(
  id: hit.id,
  who: hit.who,
  stroke: hit.stroke,
  at: hitAnchor(record, hit),
  timeS: hit.frame / (record.fps > 0 ? record.fps : 30.0),
);

/// Return every hit whose playback moment is in the current announcement window.
List<HitBurstEvent> hitBurstsAt(ClipRecord record, int frameIndex) {
  final oldest = frameIndex - kHitBurstWindowS * (record.fps > 0 ? record.fps : 30.0);
  final recent = <HitBurstEvent>[];
  for (final hit in record.hits.reversed) {
    if (hit.frame > frameIndex) continue;
    if (hit.frame < oldest) break;
    recent.add(hitBurstEvent(record, hit));
  }
  return recent.reversed.toList();
}
