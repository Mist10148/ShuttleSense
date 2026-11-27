import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_skin.dart';
import '../../../core/theme/skins/denia_art.dart';
import '../../../core/theme/skins/skin_decor.dart';

/// One place on the sticker grid: a sticker ([art]) or a quote pill ([line]).
@immutable
class StickerSpot {
  const StickerSpot({
    required this.center,
    required this.height,
    required this.tilt,
    this.art,
    this.line,
  });

  final Offset center;
  final double height;
  final double tilt;
  final int? art;
  final int? line;
}

/// Where the stickers go (Wonderboard decor.ts): a grid of 340 px cells, 70% of them used,
/// each sticker 104 to 168 tall and tilted up to 0.24 rad. About one cell in 28 holds a short
/// line instead. Centres move at most 60 px from their cell's centre, so stickers stay at
/// least 220 apart (Wonderboard asks for 190). The same size always gives the same layout.
List<StickerSpot> placeStickers(Size size, {required int artCount, required int lineCount}) {
  const cell = 340.0;
  final spots = <StickerSpot>[];
  if (artCount == 0) return spots;
  final cols = (size.width / cell).ceil(), rows = (size.height / cell).ceil();
  for (var j = 0; j < rows; j++) {
    for (var i = 0; i < cols; i++) {
      final r = Random(_hash(i, j));
      if (r.nextDouble() >= 0.7) continue;
      final center = Offset(
        (i + 0.5) * cell + (r.nextDouble() - 0.5) * 120,
        (j + 0.5) * cell + (r.nextDouble() - 0.5) * 120,
      );
      final height = 104 + r.nextDouble() * 64;
      final tilt = (r.nextDouble() - 0.5) * 0.48;
      final pick = r.nextInt(1 << 20);
      if (lineCount > 0 && r.nextDouble() < 1 / 28) {
        spots.add(
          StickerSpot(center: center, height: height, tilt: tilt / 2, line: pick % lineCount),
        );
      } else {
        spots.add(StickerSpot(center: center, height: height, tilt: tilt, art: pick % artCount));
      }
    }
  }
  return spots;
}

int _hash(int i, int j) => ((i * 73856093) ^ (j * 19349663) ^ 0x5bd1e995) & 0x7fffffff;

/// The Denia stickers scattered behind the pages. They never animate here (like Wonderboard's
/// canvas, which shows a GIF's first frame) and never take input.
class DeniaStickers extends StatelessWidget {
  const DeniaStickers({super.key, required this.strength});

  final StickerStrength strength;

  @override
  Widget build(BuildContext context) {
    final decor = SkinDecor.of(context);
    final art = DeniaArtCatalog.setFor(dark: decor.isDark);
    final opacity = strength.opacity * (decor.isDark ? 0.85 : 1);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: TickerMode(
          enabled: false,
          child: RepaintBoundary(
            child: LayoutBuilder(
              builder: (context, box) {
                final spots = placeStickers(
                  box.biggest,
                  artCount: art.length,
                  lineCount: DeniaArtCatalog.lines.length,
                );
                return Opacity(
                  opacity: opacity,
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      for (final s in spots)
                        Positioned(
                          left: s.center.dx - s.height / 2,
                          top: s.center.dy - s.height / 2,
                          width: s.height,
                          height: s.height,
                          child: Transform.rotate(
                            angle: s.tilt,
                            child: s.art != null
                                ? _Sticker(art[s.art!])
                                : Center(child: _QuotePill(DeniaArtCatalog.lines[s.line!], decor)),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Sticker extends StatelessWidget {
  const _Sticker(this.art);

  final DeniaArt art;

  @override
  Widget build(BuildContext context) => art.isSvg
      ? SvgPicture.asset(art.asset, fit: BoxFit.contain)
      : Image.asset(
          art.asset,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
}

class _QuotePill extends StatelessWidget {
  const _QuotePill(this.text, this.decor);

  final String text;
  final SkinDecor decor;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: decor.pillFill,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: decor.pillRim ?? Colors.transparent, width: 1.5),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: decor.pillText,
        ),
      ),
    ),
  );
}
