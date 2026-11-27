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

/// How strongly the Denia stickers show.
enum StickerStrength {
  faint('Faint', 0.35),
  normal('Normal', 0.65),
  strong('Strong', 0.95);

  const StickerStrength(this.label, this.opacity);

  final String label;
  final double opacity;
}

/// The extras a theme can play: the switch animation, its sound, and the Denia stickers.
@immutable
class SkinFxSettings {
  const SkinFxSettings({
    this.motion = true,
    this.sound = true,
    this.stickers = true,
    this.stickerStrength = StickerStrength.normal,
  });

  final bool motion;
  final bool sound;
  final bool stickers;
  final StickerStrength stickerStrength;

  SkinFxSettings copyWith({
    bool? motion,
    bool? sound,
    bool? stickers,
    StickerStrength? stickerStrength,
  }) => SkinFxSettings(
    motion: motion ?? this.motion,
    sound: sound ?? this.sound,
    stickers: stickers ?? this.stickers,
    stickerStrength: stickerStrength ?? this.stickerStrength,
  );

  @override
  bool operator ==(Object other) =>
      other is SkinFxSettings &&
      other.motion == motion &&
      other.sound == sound &&
      other.stickers == stickers &&
      other.stickerStrength == stickerStrength;

  @override
  int get hashCode => Object.hash(motion, sound, stickers, stickerStrength);
}

/// The theme extras, each saved on the device.
class SkinFxNotifier extends Notifier<SkinFxSettings> {
  static const _motion = 'ui.skinFx.motion';
  static const _sound = 'ui.skinFx.sound';
  static const _stickers = 'ui.skinFx.stickers';
  static const _strength = 'ui.skinFx.stickerStrength';

  @override
  SkinFxSettings build() {
    final p = ref.read(sharedPreferencesProvider);
    return SkinFxSettings(
      motion: p.getBool(_motion) ?? true,
      sound: p.getBool(_sound) ?? true,
      stickers: p.getBool(_stickers) ?? true,
      stickerStrength:
          StickerStrength.values.asNameMap()[p.getString(_strength)] ?? StickerStrength.normal,
    );
  }

  Future<void> setMotion(bool on) async {
    state = state.copyWith(motion: on);
    await ref.read(sharedPreferencesProvider).setBool(_motion, on);
  }

  Future<void> setSound(bool on) async {
    state = state.copyWith(sound: on);
    await ref.read(sharedPreferencesProvider).setBool(_sound, on);
  }

  Future<void> setStickers(bool on) async {
    state = state.copyWith(stickers: on);
    await ref.read(sharedPreferencesProvider).setBool(_stickers, on);
  }

  Future<void> setStickerStrength(StickerStrength s) async {
    state = state.copyWith(stickerStrength: s);
    await ref.read(sharedPreferencesProvider).setString(_strength, s.name);
  }
}

final skinFxProvider = NotifierProvider<SkinFxNotifier, SkinFxSettings>(SkinFxNotifier.new);
