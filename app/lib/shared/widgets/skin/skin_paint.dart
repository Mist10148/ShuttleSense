import 'dart:ui' show Picture, PictureRecorder;

import 'package:flutter/material.dart';

/// Paints a CSS-style `radial-gradient(ellipse rx ry at cx cy, ...)` over the whole [size].
/// [at] is the centre as a fraction of the size; [rx] and [ry] are the radii as fractions of
/// the width and height. Past the last stop the last colour continues, as in CSS.
void paintEllipseGradient(
  Canvas canvas,
  Size size, {
  required Offset at,
  required double rx,
  required double ry,
  required List<Color> colors,
  required List<double> stops,
}) {
  final c = Offset(size.width * at.dx, size.height * at.dy);
  final sx = size.width * rx, sy = size.height * ry;
  if (sx <= 0 || sy <= 0) return;
  canvas.save();
  canvas.translate(c.dx, c.dy);
  canvas.scale(sx, sy);
  final paint = Paint()
    ..shader = RadialGradient(
      colors: colors,
      stops: stops,
    ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1));
  canvas.drawRect(
    Rect.fromLTRB(-c.dx / sx, -c.dy / sy, (size.width - c.dx) / sx, (size.height - c.dy) / sy),
    paint,
  );
  canvas.restore();
}

/// Paints a CSS-style `linear-gradient(to bottom, ...)` over the whole [size].
void paintVerticalGradient(
  Canvas canvas,
  Size size, {
  required List<Color> colors,
  required List<double> stops,
}) {
  final rect = Offset.zero & size;
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: colors,
        stops: stops,
      ).createShader(rect),
  );
}

/// Draws [tile] (recorded at [tileSize]) repeatedly over [size], starting at the top left.
void paintTiled(Canvas canvas, Size size, Picture tile, Size tileSize) {
  for (var y = 0.0; y < size.height; y += tileSize.height) {
    for (var x = 0.0; x < size.width; x += tileSize.width) {
      canvas.save();
      canvas.translate(x, y);
      canvas.clipRect(Offset.zero & tileSize);
      canvas.drawPicture(tile);
      canvas.restore();
    }
  }
}

/// Records [draw] once into a picture of [size].
Picture recordTile(Size size, void Function(Canvas canvas) draw) {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  draw(canvas);
  return recorder.endRecording();
}
