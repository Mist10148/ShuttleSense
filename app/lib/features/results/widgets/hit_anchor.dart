import 'package:flutter/painting.dart';

import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/hit_burst.dart';
import '../../watch/court_geometry.dart';
import 'court_minimap.dart';

/// Where [hit] happened in the video picture, as fractions of its width and height.
///
/// The record keeps court positions, not pixels, so the spot is mapped back through the
/// court corners. The shuttle's court position is its pixel pushed onto the floor, so
/// mapping it back gives the shuttle's pixel again, the point of contact. Where the
/// shuttle was not seen at the hit, or its position was cut off at the limit around the
/// court, the hitter's feet are used, raised to about racket height. Null without a
/// calibrated court: the burst then goes to the hitter's half of the picture.
Offset? hitAnchor(ClipRecord record, Hit hit) {
  final corners = record.courtCorners;
  if (corners == null || corners.length != 4 || record.width <= 0 || record.height <= 0) {
    return null;
  }
  final projection = CourtProjection.fromCorners(corners);
  final frame = record.frame(hit.frame);
  if (projection == null || frame == null) return null;
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
  final feet = frame.positionOf(hit.who);
  if (feet == null) return null;
  // A player's racket is above the feet by roughly a quarter of the picture at the near
  // end and much less at the far end, where players are small.
  return toPicture(feet, raise: hit.player == 'near' ? 0.22 : 0.09);
}

/// The burst for the hit playing at [frameIndex], or nothing once it is more than
/// [kHitBurstWindowS] old (a seek far past a hit should not announce it).
List<HitBurstEvent> hitBurstsAt(ClipRecord record, int frameIndex) {
  final hit = record.hitAt(frameIndex);
  if (hit == null || frameIndex - hit.frame > kHitBurstWindowS * record.fps) return const [];
  return [HitBurstEvent(id: hit.id, who: hit.who, stroke: hit.stroke, at: hitAnchor(record, hit))];
}
