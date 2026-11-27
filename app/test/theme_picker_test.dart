// Settings > Theme (docs/THEMES.md): choosing a theme saves it, the extras are saved, the
// sticker settings show for Denia only, and Settings lays out in every theme at every size.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/audio/skin_sounds.dart';
import 'package:shuttlesense_app/core/theme/app_skin.dart';
import 'package:shuttlesense_app/features/settings/settings_screen.dart';
import 'package:shuttlesense_app/features/settings/widgets/theme_picker_card.dart';
import 'package:shuttlesense_app/features/skins/fx/skin_switch.dart';

import 'helpers.dart';

const _card = Scaffold(body: SingleChildScrollView(child: ThemePickerCard()));
final _quiet = [skinSoundsProvider.overrideWithValue(const SilentSkinSounds())];

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ThemePickerCard)));

void main() {
  testWidgets('choosing a theme with the animation off saves it at once', (tester) async {
    await pumpScreen(tester, _card, overrides: _quiet, prefs: {'ui.skinFx.motion': false});
    expect(find.text('Classic'), findsOneWidget);
    expect(find.text('Denia (Dark)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('theme-deniaDark')));
    await tester.pumpAndSettle();
    expect((await _prefs()).getString('ui.skin'), 'deniaDark');
    expect(_container(tester).read(appSkinProvider), AppSkin.deniaDark);
  });

  testWidgets('with the animation on, the choice starts a switch from Settings', (tester) async {
    await pumpScreen(tester, _card, overrides: _quiet);
    await tester.tap(find.byKey(const ValueKey('theme-backrooms')));
    await tester.pump();
    final run = _container(tester).read(skinSwitchProvider);
    expect(run?.target, AppSkin.backrooms);
    expect(run?.delayMs, greaterThan(0));
  });

  testWidgets('the card opens the theme gallery', (tester) async {
    final visited = await pumpScreen(tester, _card, overrides: _quiet);
    await tester.ensureVisible(find.byKey(const ValueKey('theme-gallery')));
    await tester.tap(find.byKey(const ValueKey('theme-gallery')));
    await tester.pumpAndSettle();
    expect(visited, ['/styleguide/themes']);
  });

  testWidgets('the extras are saved, and sticker settings show for Denia only', (tester) async {
    await pumpScreen(tester, _card, overrides: _quiet);
    expect(find.byKey(const ValueKey('theme-stickers')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('theme-sound')));
    await tester.pumpAndSettle();
    expect((await _prefs()).getBool('ui.skinFx.sound'), isFalse);
    await tester.tap(find.byKey(const ValueKey('theme-motion')));
    await tester.pumpAndSettle();
    expect((await _prefs()).getBool('ui.skinFx.motion'), isFalse);

    await tester.tap(find.byKey(const ValueKey('theme-deniaLight')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('theme-stickers')), findsOneWidget);
    await tester.ensureVisible(find.text('Strong'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Strong'));
    await tester.pumpAndSettle();
    expect((await _prefs()).getString('ui.skinFx.stickerStrength'), 'strong');
    await tester.ensureVisible(find.byKey(const ValueKey('theme-stickers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('theme-stickers')));
    await tester.pumpAndSettle();
    expect(find.text('Strong'), findsNothing);
  });

  for (final skin in AppSkin.values) {
    for (final MapEntry(key: name, value: size) in kSizes.entries) {
      testWidgets('Settings lays out in ${skin.label} on a $name', (tester) async {
        await pumpScreen(
          tester,
          const SettingsScreen(),
          size: size,
          skin: skin,
          overrides: _quiet,
          prefs: {'ui.skin': skin.name},
        );
        expect(tester.takeException(), isNull);
        expect(find.byType(ThemePickerCard), findsOneWidget);
      });
    }
  }
}
