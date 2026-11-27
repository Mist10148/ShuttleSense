import 'dart:ui' show Picture;

import 'package:flutter/material.dart';

import 'skin_paint.dart';

/// The Backrooms wallpaper (Wonderboard style.css:8): a 360x542 tile of two stripes with
/// alternating dashes and rows of chevron hexagons, drawn at 75% (270x406.5) like Wonderboard
/// at 100% zoom. The tile is recorded once and repeated.
class BackroomsWallpaperPainter extends CustomPainter {
  const BackroomsWallpaperPainter();

  static const double scale = 0.75;
  static const Size source = Size(360, 542);
  static Size get tileSize => Size(source.width * scale, source.height * scale);

  static const base = Color(0xFFB6B461);
  static const stripe = Color(0xFFA59F4A);
  static const dashDark = Color(0xFF98923F);
  static const dashLight = Color(0xFFB3AF5B);
  static const chevron = Color(0xFF9A9340);

  /// The tops of the dash pairs (dark, then light 45 below), every 180.67.
  static const dashTops = [-196.34, -15.67, 165.0, 345.67, 526.34];

  static Picture? _tile;
  static Picture get tile => _tile ??= recordTile(tileSize, (c) {
    c.scale(scale);
    paintSourceTile(c);
  });

  /// One tile in source coordinates (360x542).
  static void paintSourceTile(Canvas c) {
    c.drawRect(Offset.zero & source, Paint()..color = base);
    final stripePaint = Paint()..color = stripe;
    for (final x in [63.0, 243.0]) {
      c.drawRect(Rect.fromLTWH(x, 0, 54, source.height), stripePaint);
    }
    final dark = Paint()..color = dashDark, light = Paint()..color = dashLight;
    for (final x in [85.0, 265.0]) {
      for (final y in dashTops) {
        c.drawRect(Rect.fromLTWH(x, y, 10, 45), dark);
        c.drawRect(Rect.fromLTWH(x, y + 45, 10, 45), light);
      }
    }
    final chev = Paint()..color = chevron;
    // the middle column, and the two edge columns half a tile up and down
    for (final (cx, tops) in [
      (180.0, [248.0]),
      (0.0, [-27.0, 515.0]),
      (360.0, [-27.0, 515.0]),
    ]) {
      for (final top in tops) {
        c.drawPath(_bigChevron(cx, top), chev);
        c.drawPath(_smallChevron(cx, top + 121), chev);
      }
    }
  }

  // 180,248 235,310 235,395 180,336 125,395 125,310 (relative to the top point)
  static Path _bigChevron(double cx, double top) => Path()
    ..moveTo(cx, top)
    ..lineTo(cx + 55, top + 62)
    ..lineTo(cx + 55, top + 147)
    ..lineTo(cx, top + 88)
    ..lineTo(cx - 55, top + 147)
    ..lineTo(cx - 55, top + 62)
    ..close();

  // 180,369 235,432 235,463 180,402 125,463 125,432
  static Path _smallChevron(double cx, double top) => Path()
    ..moveTo(cx, top)
    ..lineTo(cx + 55, top + 63)
    ..lineTo(cx + 55, top + 94)
    ..lineTo(cx, top + 33)
    ..lineTo(cx - 55, top + 94)
    ..lineTo(cx - 55, top + 63)
    ..close();

  @override
  void paint(Canvas canvas, Size size) => paintTiled(canvas, size, tile, tileSize);

  @override
  bool shouldRepaint(BackroomsWallpaperPainter oldDelegate) => false;
}
