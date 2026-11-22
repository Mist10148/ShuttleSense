// Design tokens: text placed on a status or player colour stays readable (WCAG AA, 4.5:1).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  test('text on line-call and player colours meets 4.5:1 in both themes', () {
    for (final status in [StatusColors.light, StatusColors.dark]) {
      for (final c in [status.inCall, status.outCall, status.uncertain]) {
        expect(_contrast(c, onColor(c)), greaterThanOrEqualTo(4.5), reason: '$c');
      }
    }
    for (final players in [AppTheme.playerColorsLight, AppTheme.playerColorsDark]) {
      for (final c in [players.near, players.far, players.near2, players.far2]) {
        expect(_contrast(c, onColor(c)), greaterThanOrEqualTo(4.5), reason: '$c');
      }
    }
  });

  test('palette text and ink combinations meet 4.5:1 in both themes', () {
    for (final p in [AppPalette.light, AppPalette.dark]) {
      for (final bg in [p.surface, p.surface2, ...p.pastels]) {
        for (final fg in [p.ink, p.text2]) {
          expect(_contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '$fg on $bg');
        }
      }
      for (final bg in [p.surface, p.surface2]) {
        expect(_contrast(p.text3, bg), greaterThanOrEqualTo(4.5), reason: 'text3 on $bg');
      }
      expect(_contrast(p.onInk, p.ink), greaterThanOrEqualTo(4.5));
    }
  });

  test('both themes carry the palette and use the Outfit font', () {
    expect(AppTheme.light().extension<AppPalette>(), AppPalette.light);
    expect(AppTheme.dark().extension<AppPalette>(), AppPalette.dark);
    expect(AppTheme.light().textTheme.bodyMedium?.fontFamily, AppTheme.fontFamily);
  });

  test('both themes carry the status colours', () {
    expect(AppTheme.light().extension<StatusColors>(), StatusColors.light);
    expect(AppTheme.dark().extension<StatusColors>(), StatusColors.dark);
    expect(StatusColors.light.forCall(isIn: true, review: true), StatusColors.light.uncertain);
  });
}
