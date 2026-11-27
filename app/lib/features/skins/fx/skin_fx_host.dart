import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  @override
  Widget build(BuildContext context) {
    final run = ref.watch(skinSwitchProvider);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => SkinFxHost.lastTap = (e.position, DateTime.now()),
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
