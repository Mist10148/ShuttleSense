import 'package:flutter/material.dart';

import '../app_skin.dart';
import '../app_theme.dart';
import 'backrooms_tokens.dart';
import 'denia_tokens.dart';
import 'skin_bundle.dart';

/// The token bundle of a theme; null for Classic, which keeps its light and dark pair.
SkinBundle? bundleFor(AppSkin skin) => switch (skin) {
  AppSkin.classic => null,
  AppSkin.backrooms => BackroomsTokens.bundle,
  AppSkin.deniaLight => DeniaLightTokens.bundle,
  AppSkin.deniaDark => DeniaDarkTokens.bundle,
};

/// The themes MaterialApp needs for [skin]: Classic gives its light and dark pair, any other
/// theme gives its own ThemeData in both slots so the system mode cannot swap it out.
({ThemeData light, ThemeData dark, ThemeData lightHc, ThemeData darkHc}) themesFor(AppSkin skin) {
  final b = bundleFor(skin);
  if (b == null) {
    return (
      light: AppTheme.light(),
      dark: AppTheme.dark(),
      lightHc: AppTheme.light(highContrast: true),
      darkHc: AppTheme.dark(highContrast: true),
    );
  }
  final theme = AppTheme.fromBundle(b);
  final hc = AppTheme.fromBundle(b, highContrast: true);
  return (light: theme, dark: theme, lightHc: hc, darkHc: hc);
}

/// One theme's ThemeData, for previews and tests ([brightness] picks Classic's half).
ThemeData skinTheme(
  AppSkin skin, {
  Brightness brightness = Brightness.light,
  bool highContrast = false,
}) {
  final b = bundleFor(skin);
  if (b != null) return AppTheme.fromBundle(b, highContrast: highContrast);
  return brightness == Brightness.dark
      ? AppTheme.dark(highContrast: highContrast)
      : AppTheme.light(highContrast: highContrast);
}
