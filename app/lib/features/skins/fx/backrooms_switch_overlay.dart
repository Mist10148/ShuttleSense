import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/skin_sounds.dart';
import 'backrooms_plan.dart';
import 'skin_switch.dart';

/// The switch into Backrooms (Wonderboard backroomsSwitch.ts): a click and a black screen,
/// the theme changes behind it, the logo appears, then a second click and the hum as the
/// cover lifts and the logo fades out. The hum plays on after the overlay is gone; a newer
/// theme change stops it.
class BackroomsSwitchOverlay extends ConsumerStatefulWidget {
  const BackroomsSwitchOverlay({super.key, required this.run});

  final SkinSwitchRun run;

  static const logoAsset = 'assets/skins/backrooms/logo.png';

  @override
  ConsumerState<BackroomsSwitchOverlay> createState() => _BackroomsSwitchOverlayState();
}

class _BackroomsSwitchOverlayState extends ConsumerState<BackroomsSwitchOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.run.endAt),
  );
  bool _started = false, _applied = false, _revealed = false;

  SkinSwitchRun get run => widget.run;
  double get _ms => _clock.value * run.endAt - run.delayMs;

  @override
  void initState() {
    super.initState();
    _clock
      ..addListener(_tick)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) ref.read(skinSwitchProvider.notifier).finish(run);
      })
      ..forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // decode the logo now, so it appears at once
    precacheImage(const AssetImage(BackroomsSwitchOverlay.logoAsset), context);
  }

  void _tick() {
    final t = _ms;
    final sounds = ref.read(skinSoundsProvider);
    if (!_started && t >= 0) {
      _started = true;
      if (run.sound) sounds.backroomsClick();
    }
    if (!_applied && t >= BackroomsPlan.applyAt) {
      _applied = true;
      ref.read(skinSwitchProvider.notifier).apply(run);
    }
    if (!_revealed && t >= BackroomsPlan.revealAt) {
      _revealed = true;
      if (run.sound) {
        sounds.backroomsClick();
        sounds.backroomsHum();
      }
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _clock,
    builder: (context, _) {
      final t = _ms;
      if (t < 0) return const SizedBox.shrink();
      final covered = t < BackroomsPlan.revealAt;
      final logo = t < BackroomsPlan.logoAt
          ? 0.0
          : covered
          ? 1.0
          : (1 - (t - BackroomsPlan.revealAt) / BackroomsPlan.logoFadeMs).clamp(0.0, 1.0);
      final size = MediaQuery.sizeOf(context);
      return ExcludeSemantics(
        child: IgnorePointer(
          ignoring: !covered,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // the cover takes the taps while it is up, like Wonderboard's
              if (covered) const ColoredBox(color: Colors.black),
              if (logo > 0)
                Center(
                  child: Opacity(
                    opacity: logo,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.min(size.width * 0.72, 820),
                        maxHeight: size.height * 0.6,
                      ),
                      child: Image.asset(
                        BackroomsSwitchOverlay.logoAsset,
                        key: const ValueKey('backrooms-logo'),
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
