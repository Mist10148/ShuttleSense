// D54: the Light/Dark switch (navigation rail, Settings > Appearance) moves Denia to its
// matching side, tells the user Backrooms has no dark side, and leaves Classic to follow the
// mode by itself.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/audio/skin_sounds.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/theme/app_skin.dart';
import 'package:shuttlesense_app/core/theme/theme_mode.dart';
import 'package:shuttlesense_app/features/skins/fx/skin_fx_host.dart';
import 'package:shuttlesense_app/features/skins/fx/skin_switch.dart';

late ProviderContainer _c;

Future<void> _pump(WidgetTester tester, AppSkin skin) async {
  SharedPreferences.setMockInitialValues({'ui.skin': skin.name});
  final p = await SharedPreferences.getInstance();
  _c = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(p),
      skinSoundsProvider.overrideWithValue(const SilentSkinSounds()),
    ],
  );
  addTearDown(_c.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _c,
      child: MaterialApp(
        // Reduced motion: the theme changes at once, so the test needs no animation.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: SkinFxHost(child: child!),
        ),
        home: const Scaffold(body: Text('page')),
      ),
    ),
  );
}

Future<void> _setMode(WidgetTester tester, ThemeMode mode) async {
  await _c.read(themeModeProvider.notifier).set(mode);
  await tester.pump();
}

void main() {
  test('skinForMode maps only Denia', () {
    expect(skinForMode(AppSkin.deniaLight, dark: true), AppSkin.deniaDark);
    expect(skinForMode(AppSkin.deniaDark, dark: false), AppSkin.deniaLight);
    expect(skinForMode(AppSkin.deniaLight, dark: false), isNull);
    expect(skinForMode(AppSkin.deniaDark, dark: true), isNull);
    expect(skinForMode(AppSkin.classic, dark: true), isNull);
    expect(skinForMode(AppSkin.backrooms, dark: true), isNull);
  });

  testWidgets('dark mode turns Denia Light into Denia Dark, and back', (tester) async {
    await _pump(tester, AppSkin.deniaLight);
    await _setMode(tester, ThemeMode.dark);
    expect(_c.read(appSkinProvider), AppSkin.deniaDark);
    await _setMode(tester, ThemeMode.light);
    expect(_c.read(appSkinProvider), AppSkin.deniaLight);
  });

  testWidgets('Backrooms stays and says it has no dark version', (tester) async {
    await _pump(tester, AppSkin.backrooms);
    await _setMode(tester, ThemeMode.dark);
    expect(_c.read(appSkinProvider), AppSkin.backrooms);
    await tester.pump();
    expect(find.textContaining('Backrooms has no dark version'), findsOneWidget);
  });

  testWidgets('Classic is left to follow the mode itself', (tester) async {
    await _pump(tester, AppSkin.classic);
    await _setMode(tester, ThemeMode.dark);
    expect(_c.read(appSkinProvider), AppSkin.classic);
    expect(find.byType(SnackBar), findsNothing);
  });
}
