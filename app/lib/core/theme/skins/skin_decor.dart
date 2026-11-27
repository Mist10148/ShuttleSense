import 'package:flutter/material.dart';

import '../app_skin.dart';

/// What a theme paints around the tactile surfaces (docs/THEMES.md): read by the backdrop,
/// the lace edge and the switch animation. Classic paints nothing extra.
@immutable
class SkinDecor extends ThemeExtension<SkinDecor> {
  const SkinDecor({
    required this.skin,
    this.lace,
    this.accent2,
    this.gold,
    this.focus,
    this.pillFill,
    this.pillRim,
    this.pillText,
  });

  final AppSkin skin;

  /// The scallops along the lower edge of bars and headers (Denia).
  final Color? lace;

  /// A second accent: Denia (Dark)'s pink.
  final Color? accent2;

  /// A small gold touch for active controls (Denia).
  final Color? gold;

  /// Focus rings: the blue of Denia's gem, apart from the pink or violet accent.
  final Color? focus;

  /// The quote pills scattered between the stickers.
  final Color? pillFill;
  final Color? pillRim;
  final Color? pillText;

  SkinFamily get family => skin.family;
  bool get isDark => skin.isDark;

  static const classic = SkinDecor(skin: AppSkin.classic);

  static SkinDecor of(BuildContext context) => Theme.of(context).extension<SkinDecor>() ?? classic;

  @override
  SkinDecor copyWith() => this;

  // A theme change snaps halfway, like AppPalette: decoration is never blended.
  @override
  SkinDecor lerp(SkinDecor? other, double t) => other == null || t < 0.5 ? this : other;
}
