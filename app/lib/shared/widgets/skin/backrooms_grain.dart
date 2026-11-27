import 'dart:math';
import 'dart:ui' show Picture;

import 'package:flutter/material.dart';

import 'skin_paint.dart';

/// Damp plaster grain over the Backrooms wall (Wonderboard cropAndZoom.css:28): a pale warm
/// speck layer and a dark olive one. Wonderboard uses SVG fractal noise; here a seeded tile of
/// specks is recorded once, so it is the same on every run and costs one picture per tile.
class BackroomsGrainPainter extends CustomPainter {
  const BackroomsGrainPainter();

  static const Size tileSize = Size(160, 160);
  static const _light = Color.fromRGBO(255, 250, 199, 1);
  static const _dark = Color.fromRGBO(51, 48, 8, 1);

  static Picture? _tile;
  static Picture get tile => _tile ??= recordTile(tileSize, paintTile);

  /// The specks of one tile: seed 5 for the light layer and 11 for the dark, as in Wonderboard.
  static void paintTile(Canvas c) {
    void layer(int seed, int count, Color color, double maxAlpha, double maxSize) {
      final r = Random(seed);
      final paint = Paint();
      for (var i = 0; i < count; i++) {
        final s = 0.6 + r.nextDouble() * maxSize;
        paint.color = color.withValues(alpha: r.nextDouble() * maxAlpha);
        c.drawRect(
          Rect.fromLTWH(r.nextDouble() * tileSize.width, r.nextDouble() * tileSize.height, s, s),
          paint,
        );
      }
    }

    layer(5, 520, _light, 0.32, 1.4);
    layer(11, 680, _dark, 0.2, 1.1);
  }

  @override
  void paint(Canvas canvas, Size size) => paintTiled(canvas, size, tile, tileSize);

  @override
  bool shouldRepaint(BackroomsGrainPainter oldDelegate) => false;
}
