import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/skin_sounds.dart';
import '../../../core/theme/app_skin.dart';
import '../../../core/theme/theme_mode.dart';

import 'backrooms_switch_overlay.dart';
import 'denia_switch_overlay.dart';
import 'skin_switch.dart';

/// Shows the running theme switch over the whole app (MaterialApp.builder), and remembers the
/// last tap so the Denia iris grows from where the user chose the theme.
class SkinFxHost extends ConsumerStatefulWidget {
  const SkinFxHost({super.key, required this.child});

  final Widget child;

  /// The last tap in window coordinates, and when it happened.
  static (Offset, DateTime)? lastTap;

  /// The last tap if it was a moment ago (Wonderboard: 4 s), else null.
  static Offset? recentTap([DateTime? now]) {
    final t = lastTap;
    if (t == null) return null;
    return (now ?? DateTime.now()).difference(t.$2) < const Duration(seconds: 4) ? t.$1 : null;
  }

  @override
  ConsumerState<SkinFxHost> createState() => _SkinFxHostState();
}

class _SkinFxHostState extends ConsumerState<SkinFxHost> {
  /// The Light/Dark switch (navigation rail, Settings > Appearance) also moves a theme with a
  /// light and a dark side to the matching one; Backrooms only has a light side (D54).
  void _followMode(ThemeMode mode) {
    final AppSkin skin = ref.read(skinSwitchProvider)?.target ?? ref.read(appSkinProvider);
    final dark = switch (mode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context) == Brightness.dark,
    };
    final to = skinForMode(skin, dark: dark);
    if (to != null) {
      ref
          .read(skinSwitchProvider.notifier)
          .request(
            to,
            reduceMotion: MediaQuery.disableAnimationsOf(context),
            origin: SkinFxHost.recentTap(),
          );
    } else if (skin == AppSkin.backrooms && dark) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Backrooms has no dark version. Pick another theme in Settings.'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(themeModeProvider, (prev, next) {
      if (prev != next) _followMode(next);
    });
    final run = ref.watch(skinSwitchProvider);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) {
        SkinFxHost.lastTap = (e.position, DateTime.now());
        ref.read(skinSoundsProvider).unlock();
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (run != null)
            Positioned.fill(
              child: switch (run.kind) {
                BackroomsSwitch() => BackroomsSwitchOverlay(key: ValueKey(run.id), run: run),
                DeniaSwitch(:final kind) => DeniaSwitchOverlay(
                  key: ValueKey(run.id),
                  run: run,
                  kind: kind,
                ),
              },
            ),
        ],
      ),
    );
  }
}
