import 'package:flutter/material.dart';

import '../../../core/theme/skins/skin_decor.dart';

/// A row of small lace scallops (Wonderboard denia.css:24): dots of 2.6 px every 11 px, cut
/// by the top of a 5 px strip, so they hang from the edge above. Draws nothing outside Denia.
class DeniaLace extends StatelessWidget {
  const DeniaLace({super.key, this.color});

  /// Defaults to the theme's lace colour.
  final Color? color;

  static const double height = 5;

  @override
  Widget build(BuildContext context) {
    final c = color ?? SkinDecor.of(context).lace;
    if (c == null) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(painter: DeniaLacePainter(c)),
      ),
    );
  }
}

class DeniaLacePainter extends CustomPainter {
  const DeniaLacePainter(this.color);

  final Color color;

  static const double step = 11;
  static const double radius = 2.6;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()..color = color;
    // radial-gradient(circle at 50% 100%, ...) in an 11x5 cell: each dot sits on the bottom
    // edge of its cell, so a half-disc shows. Flipped here so the scallops hang down.
    for (var x = step / 2; x < size.width + step; x += step) {
      canvas.drawCircle(Offset(x, 0), radius, paint);
    }
  }

  @override
  bool shouldRepaint(DeniaLacePainter oldDelegate) => oldDelegate.color != color;
}
