import 'package:flutter/material.dart';

import 'skin_paint.dart';

/// A soft stage light fixed to the window (Wonderboard denia.css:14-21). Light: a white spot
/// from above, a pink edge and a pale blue floor. Dark: a violet spot, a near-black vignette
/// and a faint blue floor.
class DeniaStageLightPainter extends CustomPainter {
  const DeniaStageLightPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final floor = dark
        ? const Color.fromRGBO(60, 110, 190, 1)
        : const Color.fromRGBO(184, 221, 243, 1);
    final edge = dark ? const Color.fromRGBO(4, 2, 10, 1) : const Color.fromRGBO(226, 140, 182, 1);
    final spot = dark ? const Color.fromRGBO(201, 139, 255, 1) : const Color(0xFFFFFFFF);

    // linear-gradient(to bottom, transparent 60%, floor 100%)
    paintVerticalGradient(
      canvas,
      size,
      colors: [
        floor.withValues(alpha: 0),
        floor.withValues(alpha: dark ? 0.10 : 0.20),
      ],
      stops: const [0.6, 1],
    );
    // radial-gradient(ellipse 130% 105% at 50% 26%, transparent 54% (50% dark), edge 100%)
    paintEllipseGradient(
      canvas,
      size,
      at: const Offset(0.5, 0.26),
      rx: 1.3,
      ry: 1.05,
      colors: [
        edge.withValues(alpha: 0),
        edge.withValues(alpha: dark ? 0.55 : 0.24),
      ],
      stops: [dark ? 0.5 : 0.54, 1],
    );
    // radial-gradient(ellipse 72% 52% at 50% -10%, spot, spot 46%, transparent 76%)
    paintEllipseGradient(
      canvas,
      size,
      at: const Offset(0.5, -0.1),
      rx: 0.72,
      ry: 0.52,
      colors: [
        spot.withValues(alpha: dark ? 0.20 : 0.78),
        spot.withValues(alpha: dark ? 0.07 : 0.25),
        spot.withValues(alpha: 0),
      ],
      stops: const [0, 0.46, 0.76],
    );
  }

  @override
  bool shouldRepaint(DeniaStageLightPainter oldDelegate) => oldDelegate.dark != dark;
}
