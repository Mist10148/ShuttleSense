// Themes (docs/THEMES.md, D49): every theme keeps text at 4.5:1 and key edges at 3:1 on the
// surfaces they sit on, carries every token extension, and goes flat for high contrast.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_skin.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/core/theme/skins/skin_bundle.dart';
import 'package:shuttlesense_app/core/theme/skins/skin_decor.dart';
import 'package:shuttlesense_app/core/theme/skins/skin_theme.dart';
import 'package:shuttlesense_app/ui/depth.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Every theme other than Classic, with its bundle.
final _bundles = {
  for (final s in AppSkin.values)
    if (bundleFor(s) != null) s: bundleFor(s)!,
};

void main() {
  test('every theme but Classic has a bundle with the brightness it declares', () {
    expect(_bundles.keys, containsAll([AppSkin.backrooms, AppSkin.deniaLight, AppSkin.deniaDark]));
    expect(bundleFor(AppSkin.classic), isNull);
    for (final MapEntry(key: skin, value: b) in _bundles.entries) {
      expect(b.brightness, skin.brightness, reason: skin.name);
      expect(b.decor.skin, skin, reason: skin.name);
    }
  });

  test('palette text keeps 4.5:1 on surfaces and pastels', () {
    for (final MapEntry(key: skin, value: SkinBundle(palette: p)) in _bundles.entries) {
      for (final bg in [p.surface, p.surface2, ...p.pastels]) {
        for (final fg in [p.ink, p.text2]) {
          expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '${skin.name}: $fg on $bg');
        }
      }
      for (final bg in [p.surface, p.surface2, p.page]) {
        expect(_contrast(p.text3, bg), greaterThanOrEqualTo(4.5), reason: '${skin.name}: text3');
      }
      expect(_contrast(p.onInk, p.ink), greaterThanOrEqualTo(4.5), reason: skin.name);
    }
  });

  test('tactile surfaces keep text at 4.5:1 and pastel caps stay readable', () {
    for (final MapEntry(key: skin, value: b) in _bundles.entries) {
      final p = b.palette, t = b.tactile;
      for (final bg in [t.raisedTop, t.raisedBottom, t.recess, t.screenTop, t.screenBottom]) {
        for (final fg in [p.ink, p.text2, t.engraved]) {
          expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '${skin.name}: $fg on $bg');
        }
      }
      for (final bg in [t.chassisTop, t.chassisBottom]) {
        expect(_contrast(p.ink, bg), greaterThanOrEqualTo(4.5), reason: '${skin.name}: ink');
        expect(_contrast(t.engraved, bg), greaterThanOrEqualTo(4.5), reason: '${skin.name}: engr');
      }
      for (final pastel in p.pastels) {
        final top = Color.lerp(pastel, Colors.white, t.capSheen)!;
        expect(_contrast(p.ink, top), greaterThanOrEqualTo(4.5), reason: '${skin.name}: cap');
        expect(_contrast(p.text2, top), greaterThanOrEqualTo(4.5), reason: '${skin.name}: cap');
      }
      for (final bg in [t.primary, t.primaryDeep]) {
        expect(_contrast(t.onPrimary, bg), greaterThanOrEqualTo(4.5), reason: '${skin.name}: key');
      }
    }
  });

  test('accents and status marks keep 3:1 against the page and cards (WCAG 1.4.11)', () {
    for (final MapEntry(key: skin, value: b) in _bundles.entries) {
      final p = b.palette;
      for (final bg in [p.surface, p.page]) {
        for (final edge in [b.tactile.primary, b.depth.accent, p.brand, p.info]) {
          expect(_contrast(edge, bg), greaterThanOrEqualTo(3), reason: '${skin.name}: $edge');
        }
        expect(
          _contrast(b.analysis.accentInk, bg),
          greaterThanOrEqualTo(4.5),
          reason: '${skin.name}: analysis ink',
        );
        if (b.decor.focus != null) {
          expect(_contrast(b.decor.focus!, bg), greaterThanOrEqualTo(3), reason: skin.name);
        }
      }
    }
  });

  test('neumorphism needs a page and plate that differ and are not pure white or black', () {
    for (final MapEntry(key: skin, value: b) in _bundles.entries) {
      expect(b.depth.page, isNot(b.depth.bg), reason: skin.name);
      for (final c in [b.depth.page, b.tactile.chassisTop]) {
        expect(c, isNot(const Color(0xFFFFFFFF)), reason: skin.name);
        expect(c, isNot(const Color(0xFF000000)), reason: skin.name);
      }
    }
  });

  test('line-call and player colours stay the Classic ones', () {
    for (final b in _bundles.values) {
      expect(b.status, b.isDark ? StatusColors.dark : StatusColors.light);
      expect(b.players, b.isDark ? AppTheme.playerColorsDark : AppTheme.playerColorsLight);
    }
  });

  test('each theme registers all of its tokens', () {
    for (final MapEntry(key: skin, value: b) in _bundles.entries) {
      final theme = skinTheme(skin);
      expect(theme.brightness, b.brightness, reason: skin.name);
      expect(theme.extension<AppPalette>(), b.palette);
      expect(theme.extension<TactileTokens>(), b.tactile);
      expect(theme.extension<DepthTheme>(), b.depth);
      expect(theme.extension<AnalysisColors>(), b.analysis);
      expect(theme.extension<SkinDecor>(), b.decor);
      expect(theme.extension<StatusColors>(), b.status);
      expect(theme.colorScheme.primary, b.palette.ink);
      expect(theme.scaffoldBackgroundColor, b.palette.page);
      expect(theme.textTheme.bodyMedium?.fontFamily, AppTheme.fontFamily);
    }
    expect(skinTheme(AppSkin.classic).extension<SkinDecor>(), SkinDecor.classic);
    expect(skinTheme(AppSkin.classic, brightness: Brightness.dark).brightness, Brightness.dark);
  });

  test('Classic keeps its light and dark pair; other themes fill both slots', () {
    final classic = themesFor(AppSkin.classic);
    expect(classic.light.brightness, Brightness.light);
    expect(classic.dark.brightness, Brightness.dark);
    for (final skin in _bundles.keys) {
      final t = themesFor(skin);
      expect(t.light.brightness, skin.brightness);
      expect(t.dark.brightness, skin.brightness);
      expect(t.lightHc.extension<TactileTokens>()!.flat, isTrue);
    }
  });

  test('high contrast collapses every theme to plain borders', () {
    for (final skin in _bundles.keys) {
      final t = skinTheme(skin, highContrast: true).extension<TactileTokens>()!;
      expect(t.flat, isTrue, reason: skin.name);
      expect(t.shade.a, 0);
      expect(t.highlight.a, 0);
      expect(t.rim.a, greaterThan(0.5));
    }
  });
}
