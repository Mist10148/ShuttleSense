import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/skin_sounds.dart';
import '../../../core/theme/app_skin.dart';
import 'backrooms_plan.dart';
import 'denia_plan.dart';

/// The animation a theme change plays (Wonderboard themeSet): into Backrooms; into, between
/// or out of the Denia themes; or none.
sealed class SkinSwitchKind {
  const SkinSwitchKind();

  /// The theme changes this many ms after the animation starts.
  int get applyAt;

  /// The overlay is gone this many ms after the animation starts.
  int get endAt;
}

class BackroomsSwitch extends SkinSwitchKind {
  const BackroomsSwitch();

  @override
  int get applyAt => BackroomsPlan.applyAt;

  @override
  int get endAt => BackroomsPlan.endAt;
}

class DeniaSwitch extends SkinSwitchKind {
  const DeniaSwitch(this.kind);

  final DeniaSwitchKind kind;

  @override
  int get applyAt => kind.plan.applyAt;

  @override
  int get endAt => kind.plan.endAt;

  @override
  bool operator ==(Object other) => other is DeniaSwitch && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

/// The animation for a change from [from] to [to], or null when it simply applies.
SkinSwitchKind? switchKindFor(AppSkin from, AppSkin to) {
  if (from == to) return null;
  if (to.family == SkinFamily.backrooms) return const BackroomsSwitch();
  if (to.family == SkinFamily.denia) {
    final form = from.family == SkinFamily.denia;
    return DeniaSwitch(switch ((form, to.isDark)) {
      (true, true) => DeniaSwitchKind.formDark,
      (true, false) => DeniaSwitchKind.formLight,
      (false, true) => DeniaSwitchKind.enterDark,
      (false, false) => DeniaSwitchKind.enterLight,
    });
  }
  if (from.family == SkinFamily.denia) return const DeniaSwitch(DeniaSwitchKind.leave);
  return null;
}

/// One running switch animation.
@immutable
class SkinSwitchRun {
  const SkinSwitchRun({
    required this.id,
    required this.kind,
    required this.target,
    required this.origin,
    this.delayMs = 0,
    this.sound = true,
    this.seed = 1,
  });

  final int id;
  final SkinSwitchKind kind;
  final AppSkin target;

  /// Where the iris grows from (the last tap), or null for the middle of the window.
  final Offset? origin;

  /// Nothing shows for this long first (Backrooms chosen in Settings).
  final int delayMs;
  final bool sound;

  /// Picks this run's bubbles and sparkles.
  final int seed;

  int get applyAt => delayMs + kind.applyAt;
  int get endAt => delayMs + kind.endAt;
}

/// Runs theme changes: one animation at a time, a newer change cancels the running one (its
/// sound stops and the newer theme wins). Reduced motion or the setting turned off apply the
/// theme at once.
class SkinSwitchController extends Notifier<SkinSwitchRun?> {
  int _nextId = 1;

  @override
  SkinSwitchRun? build() => null;

  /// Changes the theme to [to]. [reduceMotion] is MediaQuery.disableAnimationsOf at the call;
  /// [origin] the tap that asked for it; [fromSettings] waits a moment before Backrooms.
  void request(
    AppSkin to, {
    required bool reduceMotion,
    Offset? origin,
    bool fromSettings = false,
  }) {
    final AppSkin from = state?.target ?? ref.read(appSkinProvider);
    final fx = ref.read(skinFxProvider);
    ref.read(skinSoundsProvider).stopAll();
    final kind = switchKindFor(from, to);
    if (kind == null || reduceMotion || !fx.motion) {
      state = null;
      ref.read(appSkinProvider.notifier).set(to);
      return;
    }
    final id = _nextId++;
    state = SkinSwitchRun(
      id: id,
      kind: kind,
      target: to,
      origin: origin,
      delayMs: fromSettings && kind is BackroomsSwitch ? BackroomsPlan.afterSettingsMs : 0,
      sound: fx.sound,
      seed: DateTime.now().millisecondsSinceEpoch & 0xffff | 1,
    );
  }

  /// The overlay of [run] reached the moment the theme changes.
  void apply(SkinSwitchRun run) {
    if (state?.id != run.id) return;
    ref.read(appSkinProvider.notifier).set(run.target);
  }

  /// The overlay of [run] is done.
  void finish(SkinSwitchRun run) {
    if (state?.id == run.id) state = null;
  }
}

/// The theme to switch to when the Light/Dark mode changes while [skin] is chosen (D54).
/// Denia has a light and a dark side, so it follows the mode; Classic follows it by itself
/// (AppSkin.themeMode); Backrooms is light only. Null means nothing to switch.
AppSkin? skinForMode(AppSkin skin, {required bool dark}) => switch (skin) {
  AppSkin.deniaLight when dark => AppSkin.deniaDark,
  AppSkin.deniaDark when !dark => AppSkin.deniaLight,
  _ => null,
};

final skinSwitchProvider = NotifierProvider<SkinSwitchController, SkinSwitchRun?>(
  SkinSwitchController.new,
);
