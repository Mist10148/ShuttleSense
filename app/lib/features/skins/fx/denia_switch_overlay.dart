import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/skin_sounds.dart';
import '../../../shared/widgets/skin/skin_paint.dart';
import 'denia_plan.dart';
import 'skin_switch.dart';

/// The Denia switch (Wonderboard deniaSwitch.ts): an iris of colour grows from the tap and
/// covers the window when the theme changes, bubbles rise and pop, sparkles twinkle and a card
/// bounces in. It never takes input.
class DeniaSwitchOverlay extends ConsumerStatefulWidget {
  const DeniaSwitchOverlay({super.key, required this.run, required this.kind});

  final SkinSwitchRun run;
  final DeniaSwitchKind kind;

  @override
  ConsumerState<DeniaSwitchOverlay> createState() => _DeniaSwitchOverlayState();
}

class _DeniaSwitchOverlayState extends ConsumerState<DeniaSwitchOverlay>
    with SingleTickerProviderStateMixin {
  late final DeniaPlan plan = widget.kind.plan;
  late final List<DeniaBubble> bubbles = deniaBubbles(plan, widget.run.seed);
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: plan.endAt),
  );
  bool _applied = false;

  @override
  void initState() {
    super.initState();
    if (widget.run.sound) {
      ref.read(skinSoundsProvider).deniaScore(deniaScore(widget.kind, bubbles));
    }
    _clock
      ..addListener(_tick)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          ref.read(skinSwitchProvider.notifier).finish(widget.run);
        }
      })
      ..forward();
  }

  void _tick() {
    if (!_applied && _clock.value * plan.endAt >= plan.applyAt) {
      _applied = true;
      ref.read(skinSwitchProvider.notifier).apply(widget.run);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final origin = widget.run.origin ?? Offset(size.width / 2, size.height * 0.6);
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _clock,
          builder: (context, _) {
            final t = _clock.value * plan.endAt;
            return Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(
                  painter: DeniaWashPainter(t: t, plan: plan, kind: widget.kind, origin: origin),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The iris: a wash of colour clipped to a circle that grows from [origin] until the theme
/// changes, holds a moment, then fades.
class DeniaWashPainter extends CustomPainter {
  const DeniaWashPainter({
    required this.t,
    required this.plan,
    required this.kind,
    required this.origin,
  });

  final double t;
  final DeniaPlan plan;
  final DeniaSwitchKind kind;
  final Offset origin;

  static const _grow = Cubic(0.3, 0.6, 0.3, 1);

  /// The wash colours and stops: Light, Dark, and the pale goodbye (denia.css:38-40).
  static (List<Color>, List<double>) colorsFor(DeniaSwitchKind kind) => switch (kind) {
    DeniaSwitchKind.leave => (
      const [Color.fromRGBO(255, 236, 245, .9), Color.fromRGBO(240, 232, 255, .86)],
      const [0.0, 1.0],
    ),
    _ when kind.dark => (
      const [
        Color.fromRGBO(120, 70, 190, .96),
        Color.fromRGBO(44, 24, 70, .96),
        Color.fromRGBO(20, 13, 28, .97),
      ],
      const [0.0, 0.6, 1.0],
    ),
    _ => (
      const [
        Color.fromRGBO(249, 180, 214, .95),
        Color.fromRGBO(214, 186, 255, .9),
        Color.fromRGBO(184, 221, 243, .88),
      ],
      const [0.0, 0.55, 1.0],
    ),
  };

  /// The iris radius at [t] ms for a window of [size].
  static double radiusAt(double t, DeniaPlan plan, Offset origin, Size size) {
    final full =
        math.sqrt(
          math.pow(math.max(origin.dx, size.width - origin.dx), 2) +
              math.pow(math.max(origin.dy, size.height - origin.dy), 2),
        ) +
        40;
    if (t >= plan.applyAt) return full;
    return full * _grow.transform((t / plan.applyAt).clamp(0.0, 1.0));
  }

  /// The wash opacity at [t] ms: full until a moment after the change, then fading out.
  static double opacityAt(double t, DeniaPlan plan) {
    final fadeAt = math.min(0.97 * plan.endAt, plan.applyAt + 140.0);
    if (t <= fadeAt) return 1;
    return (1 - (t - fadeAt) / (plan.endAt - fadeAt)).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = radiusAt(t, plan, origin, size), o = opacityAt(t, plan);
    if (r <= 0 || o <= 0) return;
    final (colors, stops) = colorsFor(kind);
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: origin, radius: r)));
    paintEllipseGradient(
      canvas,
      size,
      at: const Offset(0.5, 1),
      rx: 0.9,
      ry: 0.8,
      colors: [for (final c in colors) c.withValues(alpha: c.a * o)],
      stops: stops,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(DeniaWashPainter old) => old.t != t || old.origin != origin;
}
