// The chosen theme and its extras are saved on the device (docs/THEMES.md).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/theme/app_skin.dart';

Future<(ProviderContainer, SharedPreferences)> _container([
  Map<String, Object> prefs = const {},
]) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(p)]);
  addTearDown(c.dispose);
  return (c, p);
}

void main() {
  test('Classic is the default and an unknown saved value falls back to it', () async {
    final (c, _) = await _container();
    expect(c.read(appSkinProvider), AppSkin.classic);
    final (c2, _) = await _container({'ui.skin': 'vaporwave'});
    expect(c2.read(appSkinProvider), AppSkin.classic);
  });

  test('the chosen theme is saved and read back', () async {
    final (c, p) = await _container();
    await c.read(appSkinProvider.notifier).set(AppSkin.deniaDark);
    expect(p.getString('ui.skin'), 'deniaDark');
    final (c2, _) = await _container({'ui.skin': 'backrooms'});
    expect(c2.read(appSkinProvider), AppSkin.backrooms);
  });

  test('Classic follows the Appearance mode; the others carry their own', () {
    for (final m in ThemeMode.values) {
      expect(AppSkin.classic.themeMode(m), m);
      expect(AppSkin.backrooms.themeMode(m), ThemeMode.light);
      expect(AppSkin.deniaLight.themeMode(m), ThemeMode.light);
      expect(AppSkin.deniaDark.themeMode(m), ThemeMode.dark);
    }
    expect(AppSkin.deniaLight.family, AppSkin.deniaDark.family);
  });

  test('every extra is on by default and each is saved on its own', () async {
    final (c, p) = await _container();
    expect(c.read(skinFxProvider), const SkinFxSettings());
    final n = c.read(skinFxProvider.notifier);
    await n.setMotion(false);
    await n.setSound(false);
    await n.setStickers(false);
    await n.setStickerStrength(StickerStrength.strong);
    expect(
      c.read(skinFxProvider),
      const SkinFxSettings(
        motion: false,
        sound: false,
        stickers: false,
        stickerStrength: StickerStrength.strong,
      ),
    );
    expect(p.getBool('ui.skinFx.motion'), isFalse);
    expect(p.getBool('ui.skinFx.sound'), isFalse);
    expect(p.getBool('ui.skinFx.stickers'), isFalse);
    expect(p.getString('ui.skinFx.stickerStrength'), 'strong');

    final (c2, _) = await _container({'ui.skinFx.sound': false, 'ui.skinFx.stickerStrength': 'x'});
    expect(c2.read(skinFxProvider).sound, isFalse);
    expect(c2.read(skinFxProvider).stickerStrength, StickerStrength.normal);
  });
}
