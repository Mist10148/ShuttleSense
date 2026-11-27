import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/server_config.dart';

/// The look of the whole app (docs/THEMES.md). [classic] is the tactile design in the light,
/// dark or system mode chosen under Appearance; every other theme carries its own brightness.
enum AppSkin {
  classic('Classic', null, SkinFamily.classic),
  backrooms('Backrooms', Brightness.light, SkinFamily.backrooms),
  deniaLight('Denia (Light)', Brightness.light, SkinFamily.denia),
  deniaDark('Denia (Dark)', Brightness.dark, SkinFamily.denia);

  const AppSkin(this.label, this.brightness, this.family);

  final String label;

  /// Null for [classic], which follows the saved theme mode.
  final Brightness? brightness;
  final SkinFamily family;

  bool get isDark => brightness == Brightness.dark;

  /// The theme mode the app runs in under this theme ([mode] is the Appearance choice).
  ThemeMode themeMode(ThemeMode mode) => switch (brightness) {
    null => mode,
    Brightness.light => ThemeMode.light,
    Brightness.dark => ThemeMode.dark,
  };
}

/// Themes that share decoration and a switch animation.
enum SkinFamily { classic, backrooms, denia }

/// The chosen theme, saved on the device.
class AppSkinNotifier extends Notifier<AppSkin> {
  static const _key = 'ui.skin';

  @override
  AppSkin build() {
    final saved = ref.read(sharedPreferencesProvider).getString(_key);
    return AppSkin.values.asNameMap()[saved] ?? AppSkin.classic;
  }

  Future<void> set(AppSkin skin) async {
    state = skin;
    await ref.read(sharedPreferencesProvider).setString(_key, skin.name);
  }
}

final appSkinProvider = NotifierProvider<AppSkinNotifier, AppSkin>(AppSkinNotifier.new);
