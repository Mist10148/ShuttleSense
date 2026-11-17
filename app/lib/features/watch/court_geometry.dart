import 'package:flutter/material.dart';
import '../../core/theme/tokens.dart';
import '../calibration/calibration_screen.dart';

const double _alley = 0.46;
const double _singlesWidth = 5.18;
const double _fullWidth = _singlesWidth + 2 * _alley;
const double _length = 13.4;

/// Maps a unit square to four ordered image points with a projective transform.
class CourtProjection {
  CourtProjection._(this.a, this.b, this.c, this.d, this.e, this.f, this.g, this.h);
  final double a, b, c, d, e, f, g, h;

  static CourtProjection? fromCorners(List<Corner> p) {
    if (!isConvex(p)) return null;
    final dx1 = p[1].x - p[2].x, dx2 = p[3].x - p[2].x;
    final dy1 = p[1].y - p[2].y, dy2 = p[3].y - p[2].y;
    final dx3 = p[0].x - p[1].x + p[2].x - p[3].x;
    final dy3 = p[0].y - p[1].y + p[2].y - p[3].y;
    final denominator = dx1 * dy2 - dx2 * dy1;
    if (denominator.abs() < 1e-9) return null;
    final g = (dx3 * dy2 - dx2 * dy3) / denominator;
    final h = (dx1 * dy3 - dx3 * dy1) / denominator;
    return CourtProjection._(
      p[1].x - p[0].x + g * p[1].x,
      p[3].x - p[0].x + h * p[3].x,
      p[0].x,
      p[1].y - p[0].y + g * p[1].y,
      p[3].y - p[0].y + h * p[3].y,
      p[0].y,
      g,
      h,
    );
  }

  Corner? point(double x, double y) {
    final z = g * x + h * y + 1;
    if (z.abs() < 1e-9) return null;
    final px = (a * x + b * y + c) / z, py = (d * x + e * y + f) / z;
    return px.isFinite && py.isFinite ? (x: px, y: py) : null;
  }
}

List<Corner>? _convert(List<Corner> corners, double left, double right) {
  final projection = CourtProjection.fromCorners(corners);
  if (projection == null) return null;
  final points = [
    projection.point(left, 0),
    projection.point(right, 0),
    projection.point(right, 1),
    projection.point(left, 1),
  ];
  if (points.any((p) => p == null)) return null;
  final result = points.cast<Corner>();
  return isConvex(result) ? result : null;
}

/// The backend expects singles corners; Watch's handles represent the full court.
List<Corner>? fullToSingles(List<Corner> full) =>
    _convert(full, _alley / _fullWidth, 1 - _alley / _fullWidth);

/// The detector currently returns singles corners; expand them in court coordinates.
List<Corner>? singlesToFull(List<Corner> singles) =>
    _convert(singles, -_alley / _singlesWidth, 1 + _alley / _singlesWidth);

/// A preview of the same painted markings used by the backend renderer.
class FullCourtPreview extends CustomPainter {
  FullCourtPreview(this.corners, this.scale);
  final List<Corner> corners;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final p = CourtProjection.fromCorners(corners);
    if (p == null) return;
    final paint = Paint()
      ..color = OverlayColors.courtLines
      ..strokeWidth = 2;
    void line(double x1, double y1, double x2, double y2) {
      final a = p.point(x1 / _fullWidth, y1 / _length);
      final b = p.point(x2 / _fullWidth, y2 / _length);
      if (a != null && b != null) {
        canvas.drawLine(Offset(a.x * scale, a.y * scale), Offset(b.x * scale, b.y * scale), paint);
      }
    }

    const left = _alley, right = _alley + _singlesWidth;
    const nearService = _length / 2 - 1.98, farService = _length / 2 + 1.98;
    line(0, 0, _fullWidth, 0);
    line(0, _length, _fullWidth, _length);
    line(0, 0, 0, _length);
    line(_fullWidth, 0, _fullWidth, _length);
    line(left, 0, left, _length);
    line(right, 0, right, _length);
    line(0, nearService, _fullWidth, nearService);
    line(0, farService, _fullWidth, farService);
    line(_fullWidth / 2, 0, _fullWidth / 2, nearService);
    line(_fullWidth / 2, farService, _fullWidth / 2, _length);
    line(0, 0.76, _fullWidth, 0.76);
    line(0, _length - 0.76, _fullWidth, _length - 0.76);
  }

  @override
  bool shouldRepaint(FullCourtPreview old) => true;
}
