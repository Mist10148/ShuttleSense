import 'package:flutter/material.dart';

import 'skin_paint.dart';

/// The fluorescent ceiling light over the Backrooms wallpaper (Wonderboard
/// cropAndZoom.css:22-25), fixed to the window: a pale warm pool from above, a darker floor
/// and an edge vignette. The floor and vignette are lighter than Wonderboard's (.46 and .30)
/// because ShuttleSense prints page titles straight on the wall and they must keep 4.5:1.
class BackroomsLightPainter extends CustomPainter {
  const BackroomsLightPainter();

  static const _dirt = Color.fromRGBO(30, 28, 4, 1);
  static const _lamp = Color.fromRGBO(255, 252, 206, 1);
  static const _edge = Color.fromRGBO(38, 36, 6, 1);

  @override
  void paint(Canvas canvas, Size size) {
    // radial-gradient(ellipse 130% 105% at 50% 22%, transparent 52%, rgba(38,36,6,.30) 100%)
    paintEllipseGradient(
      canvas,
      size,
      at: const Offset(0.5, 0.22),
      rx: 1.3,
      ry: 1.05,
      colors: [_edge.withValues(alpha: 0), _edge.withValues(alpha: 0.2)],
      stops: const [0.52, 1],
    );
    // radial-gradient(ellipse 62% 48% at 50% -6%, rgba(255,252,206,.46), .18 48%, transparent 78%)
    paintEllipseGradient(
      canvas,
      size,
      at: const Offset(0.5, -0.06),
      rx: 0.62,
      ry: 0.48,
      colors: [
        _lamp.withValues(alpha: 0.46),
        _lamp.withValues(alpha: 0.18),
        _lamp.withValues(alpha: 0),
      ],
      stops: const [0, 0.48, 0.78],
    );
    // linear-gradient(to bottom, transparent 32%, rgba(30,28,4,.18) 66%, rgba(30,28,4,.46) 100%)
    paintVerticalGradient(
      canvas,
      size,
      colors: [
        _dirt.withValues(alpha: 0),
        _dirt.withValues(alpha: 0.12),
        _dirt.withValues(alpha: 0.22),
      ],
      stops: const [0.32, 0.66, 1],
    );
  }

  @override
  bool shouldRepaint(BackroomsLightPainter oldDelegate) => false;
}
