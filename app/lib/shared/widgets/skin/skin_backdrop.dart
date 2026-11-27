import 'package:flutter/material.dart';

import '../../../core/theme/app_skin.dart';
import '../../../core/theme/skins/skin_decor.dart';
import 'backrooms_grain.dart';
import 'backrooms_light.dart';
import 'backrooms_wallpaper.dart';
import 'denia_lace.dart';
import 'denia_pattern.dart';
import 'denia_stage_light.dart';
import 'denia_stickers.dart';

/// Everything a theme paints behind the pages, bottom to top (docs/THEMES.md):
/// Backrooms: wall colour, wallpaper, plaster grain, ceiling light.
/// Denia: page colour, bubble-and-star pattern, stickers, stage light, lace along the top.
/// Classic paints nothing. Never takes input or reaches screen readers.
class SkinBackdrop extends StatelessWidget {
  const SkinBackdrop({super.key, required this.decor, required this.fx, required this.base});

  final SkinDecor decor;
  final SkinFxSettings fx;

  /// The solid colour under the decoration (the theme's page).
  final Color base;

  @override
  Widget build(BuildContext context) {
    final layers = switch (decor.family) {
      SkinFamily.classic => const <Widget>[],
      SkinFamily.backrooms => const [
        CustomPaint(painter: BackroomsWallpaperPainter()),
        CustomPaint(painter: BackroomsGrainPainter()),
        CustomPaint(painter: BackroomsLightPainter()),
      ],
      SkinFamily.denia => [
        CustomPaint(painter: DeniaPatternPainter(dark: decor.isDark)),
        if (fx.stickers) DeniaStickers(strength: fx.stickerStrength),
        CustomPaint(painter: DeniaStageLightPainter(dark: decor.isDark)),
        const Align(alignment: Alignment.topCenter, child: DeniaLace()),
      ],
    };
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: ColoredBox(
            color: base,
            child: Stack(
              fit: StackFit.expand,
              children: [for (final l in layers) Positioned.fill(child: l)],
            ),
          ),
        ),
      ),
    );
  }
}
