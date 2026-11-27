// Theme decoration (docs/THEMES.md): each backdrop renders at phone, tablet and laptop sizes,
// stickers are placed the same way every time and apart, and the scope only clears the
// page-sized fills of a decorated theme.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/theme/app_skin.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/core/theme/skins/skin_theme.dart';
import 'package:shuttlesense_app/shared/widgets/skin/backrooms_wallpaper.dart';
import 'package:shuttlesense_app/shared/widgets/skin/denia_lace.dart';
import 'package:shuttlesense_app/shared/widgets/skin/denia_pattern.dart';
import 'package:shuttlesense_app/shared/widgets/skin/denia_stickers.dart';
import 'package:shuttlesense_app/shared/widgets/skin/skin_backdrop.dart';
import 'package:shuttlesense_app/shared/widgets/skin/skin_scope.dart';

import 'helpers.dart';

Future<void> _pumpScope(
  WidgetTester tester,
  AppSkin skin, {
  Size size = phone,
  Map<String, Object> prefs = const {},
  bool highContrast = false,
}) async {
  setSize(tester, size);
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(p)],
      child: MaterialApp(
        theme: skinTheme(skin),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(highContrast: highContrast),
          child: SkinScope(child: child!),
        ),
        home: const Scaffold(body: Center(child: Text('page'))),
      ),
    ),
  );
  // MaterialApp animates a theme change; let it land.
  await tester.pumpAndSettle();
}

void main() {
  test('stickers land in the same places every time, apart and inside their cells', () {
    const size = Size(1280, 800);
    final a = placeStickers(size, artCount: 17, lineCount: 9);
    final b = placeStickers(size, artCount: 17, lineCount: 9);
    expect(a.map((s) => s.center), b.map((s) => s.center));
    expect(a, isNotEmpty);
    for (var i = 0; i < a.length; i++) {
      final s = a[i];
      expect(s.height, inInclusiveRange(104, 168));
      expect(s.tilt.abs(), lessThanOrEqualTo(0.24));
      expect((s.art == null) != (s.line == null), isTrue);
      for (var j = i + 1; j < a.length; j++) {
        expect((s.center - a[j].center).distance, greaterThanOrEqualTo(190));
      }
    }
    expect(placeStickers(size, artCount: 0, lineCount: 9), isEmpty);
  });

  test('about seven cells in ten hold something', () {
    final spots = placeStickers(const Size(340.0 * 20, 340.0 * 20), artCount: 5, lineCount: 9);
    expect(spots.length / 400, inInclusiveRange(0.6, 0.8));
    expect(spots.where((s) => s.line != null).length, lessThan(40));
  });

  test('the wallpaper and pattern tiles are recorded once and reused', () {
    expect(identical(BackroomsWallpaperPainter.tile, BackroomsWallpaperPainter.tile), isTrue);
    expect(BackroomsWallpaperPainter.tileSize, const Size(270, 406.5));
    expect(identical(DeniaPatternPainter.tileFor(true), DeniaPatternPainter.tileFor(true)), isTrue);
    expect(
      const DeniaPatternPainter(dark: true).shouldRepaint(const DeniaPatternPainter(dark: false)),
      isTrue,
    );
    expect(
      DeniaPatternPainter.star4(0, 0, 6).getBounds().center,
      offsetMoreOrLessEquals(Offset.zero),
    );
  });

  for (final skin in AppSkin.values) {
    for (final MapEntry(key: name, value: size) in kSizes.entries) {
      testWidgets('${skin.label} renders its backdrop on a $name', (tester) async {
        await _pumpScope(tester, skin, size: size);
        expect(tester.takeException(), isNull);
        expect(find.text('page'), findsOneWidget);
        expect(find.byType(SkinBackdrop), skin == AppSkin.classic ? findsNothing : findsOneWidget);
        expect(
          find.byType(DeniaStickers),
          skin.family == SkinFamily.denia ? findsOneWidget : findsNothing,
        );
      });
    }
  }

  testWidgets('drawn props get a white die-cut rim and a shadow', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox.square(
            dimension: 110,
            child: DieCutRim(
              child: ColoredBox(key: Key('shape'), color: Color(0xFFC2255C)),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // The shape itself, then the shadow and one white copy per ring step.
    expect(find.byKey(const Key('shape')), findsNWidgets(DieCutRim.copies + 2));
    final white = tester
        .widgetList<ColorFiltered>(find.byType(ColorFiltered))
        .where((c) => c.colorFilter == const ColorFilter.mode(Colors.white, BlendMode.srcIn));
    expect(white, hasLength(DieCutRim.copies));
    // Half the 220 viewBox: the ring is 2.5 px out.
    final first = tester.widgetList<Transform>(find.byType(Transform)).elementAt(1);
    expect(first.transform.getTranslation().x, closeTo(2.5, 1e-9));
  });

  testWidgets('stickers follow the setting and lace hangs in Denia only', (tester) async {
    await _pumpScope(tester, AppSkin.deniaLight, prefs: {'ui.skinFx.stickers': false});
    expect(find.byType(DeniaStickers), findsNothing);
    expect(find.byType(DeniaLace), findsOneWidget);
    await _pumpScope(tester, AppSkin.backrooms);
    expect(find.byType(DeniaLace), findsNothing);
  });

  testWidgets('high contrast drops the decoration', (tester) async {
    await _pumpScope(tester, AppSkin.backrooms, highContrast: true);
    expect(find.byType(SkinBackdrop), findsNothing);
  });

  testWidgets('pages see clear page fills but solid cards and keys', (tester) async {
    late ThemeData seen;
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(p)],
        child: MaterialApp(
          theme: skinTheme(AppSkin.deniaDark),
          builder: (context, child) => SkinScope(child: child!),
          home: Builder(
            builder: (context) {
              seen = Theme.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    final palette = seen.extension<AppPalette>()!, t = seen.extension<TactileTokens>()!;
    expect(seen.scaffoldBackgroundColor.a, 0);
    expect(palette.canvas.a, 0);
    expect(palette.popoverShadow, isEmpty);
    expect(t.chassisTop.a, 0);
    expect(t.raisedTop, skinTheme(AppSkin.deniaDark).extension<TactileTokens>()!.raisedTop);
    expect(palette.surface.a, 1);
    expect(seen.navigationBarTheme.backgroundColor!.a, 1);
  });
}
