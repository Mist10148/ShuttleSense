import 'dart:math';
import 'dart:ui' show Picture;

import 'package:flutter/material.dart';

import 'skin_paint.dart';

/// Colours of the bubble-and-star tile, Light and Dark (Wonderboard decor.ts:152-154).
@immutable
class DeniaPatternColors {
  const DeniaPatternColors({
    required this.bubble,
    required this.bubbleFill,
    required this.blue,
    required this.star,
    required this.hot,
    required this.glint,
  });

  final Color bubble, bubbleFill, blue, star, hot, glint;

  static const light = DeniaPatternColors(
    bubble: Color.fromRGBO(214, 134, 176, .42),
    bubbleFill: Color.fromRGBO(255, 255, 255, .45),
    blue: Color.fromRGBO(120, 175, 220, .42),
    star: Color.fromRGBO(226, 140, 182, .55),
    hot: Color.fromRGBO(214, 160, 60, .50),
    glint: Color.fromRGBO(255, 255, 255, .9),
  );

  static const dark = DeniaPatternColors(
    bubble: Color.fromRGBO(160, 125, 220, .34),
    bubbleFill: Color.fromRGBO(201, 139, 255, .05),
    blue: Color.fromRGBO(110, 160, 230, .30),
    star: Color.fromRGBO(185, 150, 240, .42),
    hot: Color.fromRGBO(255, 111, 174, .50),
    glint: Color.fromRGBO(240, 225, 255, .55),
  );
}

/// Soap bubbles, five- and four-point stars and a few dots on a 240 px tile, the background of
/// both Denia themes (Wonderboard decor.ts:143-168; same positions and sizes).
class DeniaPatternPainter extends CustomPainter {
  const DeniaPatternPainter({required this.dark});

  final bool dark;

  static const Size tileSize = Size(240, 240);
  static final Map<bool, Picture> _tiles = {};

  static Picture tileFor(bool dark) => _tiles[dark] ??= recordTile(
    tileSize,
    (c) => paintTile(c, dark ? DeniaPatternColors.dark : DeniaPatternColors.light),
  );

  static Path star4(double cx, double cy, double r) {
    final p = Path();
    for (var i = 0; i < 8; i++) {
      final a = i * pi / 4, rr = i.isOdd ? r * 0.32 : r;
      final o = Offset(cx + rr * sin(a), cy - rr * cos(a));
      i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
    }
    return p..close();
  }

  static Path star5(double cx, double cy, double r, double rot) {
    final p = Path();
    for (var i = 0; i < 10; i++) {
      final a = rot + i * pi / 5, rr = i.isOdd ? r * 0.45 : r;
      final o = Offset(cx + rr * sin(a), cy - rr * cos(a));
      i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy);
    }
    return p..close();
  }

  static void paintTile(Canvas c, DeniaPatternColors k) {
    void bubble(double cx, double cy, double r, Color rim) {
      c.drawCircle(Offset(cx, cy), r, Paint()..color = k.bubbleFill);
      c.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..color = rim
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      c.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r * 0.62),
        pi * 1.05,
        pi * 0.4,
        false,
        Paint()
          ..color = k.glint
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = max(0.9, r * 0.16),
      );
    }

    bubble(38, 44, 13, k.bubble);
    bubble(176, 92, 9, k.blue);
    bubble(96, 170, 17, k.bubble);
    bubble(208, 196, 6, k.blue);
    bubble(132, 36, 5, k.bubble);
    bubble(30, 150, 5, k.blue);

    final outline = Paint()
      ..color = k.star
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeJoin = StrokeJoin.round;
    c.drawPath(star5(150, 160, 8, 0.2), outline);
    c.drawPath(star5(84, 92, 6, -0.3), outline);
    c.drawPath(star5(206, 40, 5.5, 0.5), Paint()..color = k.hot);
    c.drawPath(star4(52, 208, 6), Paint()..color = k.star);
    c.drawPath(star4(118, 112, 4), Paint()..color = k.star);
    c.drawPath(star4(186, 140, 3.2), Paint()..color = k.hot);
    for (final (x, y) in const [(70.0, 20.0), (224.0, 108.0), (16.0, 96.0), (160.0, 220.0)]) {
      c.drawCircle(Offset(x, y), 1.3, Paint()..color = k.star);
    }
    c.drawCircle(const Offset(110, 226), 1.3, Paint()..color = k.star);
  }

  @override
  void paint(Canvas canvas, Size size) => paintTiled(canvas, size, tileFor(dark), tileSize);

  @override
  bool shouldRepaint(DeniaPatternPainter oldDelegate) => oldDelegate.dark != dark;
}
