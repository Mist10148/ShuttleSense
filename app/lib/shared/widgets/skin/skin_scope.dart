import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_skin.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/skins/skin_decor.dart';
import 'skin_backdrop.dart';

/// Puts the theme's backdrop behind every page (MaterialApp.builder). The shell's chassis,
/// the page canvas and Scaffolds are opaque in Classic; here they turn clear so the wallpaper
/// shows, while cards, keys, wells, bars and dialogs keep their solid tactile fills. The
/// full-window shell's drop shadow goes too: under a clear panel it would darken the wall.
/// Classic and high-contrast mode get the app unchanged.
class SkinScope extends ConsumerWidget {
  const SkinScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final decor = theme.extension<SkinDecor>() ?? SkinDecor.classic;
    if (decor.family == SkinFamily.classic || MediaQuery.highContrastOf(context)) return child;
    final p = AppPalette.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        SkinBackdrop(decor: decor, fx: ref.watch(skinFxProvider), base: p.page),
        Theme(data: clearSurfaces(theme), child: child),
      ],
    );
  }

  /// [theme] with the page-sized fills made clear (see the class comment).
  static ThemeData clearSurfaces(ThemeData theme) {
    final p = theme.extension<AppPalette>(), t = theme.extension<TactileTokens>();
    if (p == null || t == null) return theme;
    return theme.copyWith(
      scaffoldBackgroundColor: Colors.transparent,
      extensions: [
        for (final e in theme.extensions.values)
          if (e is! AppPalette && e is! TactileTokens) e,
        _clearPalette(p),
        _clearChassis(t),
      ],
    );
  }

  static AppPalette _clearPalette(AppPalette p) => AppPalette(
    ink: p.ink,
    onInk: p.onInk,
    text2: p.text2,
    text3: p.text3,
    surface: p.surface,
    surface2: p.surface2,
    hairline: p.hairline,
    lavender: p.lavender,
    sky: p.sky,
    mint: p.mint,
    pink: p.pink,
    peach: p.peach,
    brand: p.brand,
    info: p.info,
    chart: p.chart,
    progress: p.progress,
    canvas: Colors.transparent,
    canvasGlows: const [],
    page: Colors.transparent,
    shell: p.shell,
    cardShadow: p.cardShadow,
    popoverShadow: const [],
  );

  static TactileTokens _clearChassis(TactileTokens t) => TactileTokens(
    chassisTop: Colors.transparent,
    chassisBottom: Colors.transparent,
    raisedTop: t.raisedTop,
    raisedBottom: t.raisedBottom,
    recess: t.recess,
    screenTop: t.screenTop,
    screenBottom: t.screenBottom,
    highlight: t.highlight,
    shade: t.shade,
    innerShade: t.innerShade,
    innerLight: t.innerLight,
    rim: t.rim,
    engraved: t.engraved,
    engravedShadow: t.engravedShadow,
    keyEdge: t.keyEdge,
    capSheen: t.capSheen,
    primary: t.primary,
    primaryDeep: t.primaryDeep,
    onPrimary: t.onPrimary,
    flat: t.flat,
  );
}
