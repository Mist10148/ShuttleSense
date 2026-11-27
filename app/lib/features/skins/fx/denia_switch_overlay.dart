import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/skin_sounds.dart';
import '../../../core/theme/skins/denia_art.dart';
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
                CustomPaint(
                  painter: DeniaBubblesPainter(
                    t: t,
                    plan: plan,
                    kind: widget.kind,
                    bubbles: bubbles,
                    seed: widget.run.seed,
                    extraPops: [
                      if (widget.kind != DeniaSwitchKind.leave)
                        (
                          DeniaCard.outAt(plan) + 60,
                          size.center(Offset.zero),
                          220.0,
                          DeniaBubblesPainter.rims[widget.kind.dark ? 2 : 0],
                        ),
                    ],
                  ),
                ),
                if (widget.kind != DeniaSwitchKind.leave)
                  DeniaCard(t: t, plan: plan, dark: widget.kind.dark),
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

/// Rising soap bubbles that pop into a ring and droplets, and four-point sparkles
/// (deniaSwitch.ts and denia.css:41-50).
class DeniaBubblesPainter extends CustomPainter {
  DeniaBubblesPainter({
    required this.t,
    required this.plan,
    required this.kind,
    required this.bubbles,
    required this.seed,
    this.extraPops = const [],
  });

  final double t;
  final DeniaPlan plan;
  final DeniaSwitchKind kind;
  final List<DeniaBubble> bubbles;
  final int seed;

  /// Pops that are not bubbles (the card's), as (at ms, centre, size, rim).
  final List<(int, Offset, double, Color)> extraPops;

  /// Bubble rims: pink, pale blue, violet.
  static const rims = [
    Color.fromRGBO(240, 120, 170, .9),
    Color.fromRGBO(110, 170, 225, .9),
    Color.fromRGBO(160, 120, 225, .9),
  ];

  static const _riseIn = Cubic(0.2, 0.7, 0.3, 1);
  static const _riseOn = Cubic(0.3, 0.5, 0.3, 1);
  static const _ring = Cubic(0.2, 0.7, 0.3, 1);
  static const _drop = Cubic(0.15, 0.6, 0.4, 1);

  /// Where bubble [b] is at [t] ms in a window of [size]: its centre, scale and opacity, or
  /// null before it starts and once it has popped.
  static (Offset, double, double)? bubbleAt(DeniaBubble b, double t, Size size) {
    if (t < b.delay || t >= b.popAt) return null;
    final life = math.max(200, b.popAt - b.delay);
    final u = ((t - b.delay) / life).clamp(0.0, 1.0);
    final rise = -(b.rise / 100) * size.height - b.size;
    double dx, dy, scale, opacity;
    if (u < 0.4) {
      final e = _riseIn.transform(u / 0.4);
      dx = b.sway * 0.4 * e;
      dy = rise * 0.45 * e;
      scale = 0.6 + 0.4 * e;
      opacity = e;
    } else if (u < 0.96) {
      final e = _riseOn.transform((u - 0.4) / 0.56);
      dx = b.sway * (0.4 + 0.6 * e);
      dy = rise * (0.45 + 0.55 * e);
      scale = 1 + 0.04 * e;
      opacity = 1;
    } else {
      final e = (u - 0.96) / 0.04;
      dx = b.sway;
      dy = rise;
      scale = 1.04 + 0.21 * e;
      opacity = 1 - e;
    }
    final start = Offset(b.x / 100 * size.width, size.height + b.size / 2);
    return (start + Offset(dx, dy), scale, opacity);
  }

  /// Where bubble [b] pops.
  static Offset popPoint(DeniaBubble b, Size size) => Offset(
    b.x / 100 * size.width + b.sway,
    size.height - (b.rise / 100) * size.height - b.size + b.size / 2,
  );

  @override
  void paint(Canvas canvas, Size size) {
    _sparkles(canvas, size);
    for (final b in bubbles) {
      final at = bubbleAt(b, t, size);
      if (at != null) _bubble(canvas, at.$1, b.size / 2 * at.$2, rims[b.hue], at.$3);
    }
    for (final (i, b) in bubbles.indexed) {
      _pop(canvas, b.popAt, popPoint(b, size), b.size, rims[b.hue], seed * 31 + i);
    }
    for (final (i, (at, c, s, rim)) in extraPops.indexed) {
      _pop(canvas, at, c, s, rim, seed * 17 + 1000 + i);
    }
  }

  void _bubble(Canvas c, Offset center, double r, Color rim, double o) {
    if (r <= 0 || o <= 0) return;
    final box = Rect.fromCircle(center: center, radius: r);
    Color a(Color k) => k.withValues(alpha: k.a * o);
    // soap film: conic-gradient(from 210deg, pink, blue, violet, gold, pink)
    c.drawCircle(
      center,
      r,
      Paint()
        ..shader = SweepGradient(
          colors: [
            a(const Color.fromRGBO(255, 170, 210, .42)),
            a(const Color.fromRGBO(180, 220, 255, .38)),
            a(const Color.fromRGBO(205, 180, 255, .42)),
            a(const Color.fromRGBO(255, 236, 190, .36)),
            a(const Color.fromRGBO(255, 170, 210, .42)),
          ],
          transform: const GradientRotation(120 * math.pi / 180),
        ).createShader(box),
    );
    // the bright edge of the film
    c.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [
            a(const Color(0x00FFFFFF)),
            a(const Color.fromRGBO(255, 255, 255, .28)),
            a(const Color.fromRGBO(255, 255, 255, .5)),
          ],
          stops: const [0.52, 0.72, 1],
        ).createShader(box),
    );
    // the highlight, up and to the left
    c.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.36, -0.44),
          radius: 0.99,
          colors: [
            a(const Color(0xFFFFFFFF)),
            a(const Color(0xFFFFFFFF)),
            a(const Color.fromRGBO(255, 255, 255, .55)),
            a(const Color(0x00FFFFFF)),
          ],
          stops: const [0, 0.07, 0.11, 0.24],
        ).createShader(box),
    );
    c.drawCircle(
      center,
      r - 0.75,
      Paint()
        ..color = a(rim)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  /// A pop at [at] ms: a ring that widens and fades, and droplets that fly out and fall.
  void _pop(Canvas c, int at, Offset center, double size, Color rim, int dropSeed) {
    final dt = t - at;
    if (dt < 0 || dt > 620) return;
    if (dt < 320) {
      final e = _ring.transform(dt / 320);
      c.drawCircle(
        center,
        size / 2 * (1 + 0.6 * e) - 1,
        Paint()
          ..color = rim.withValues(alpha: 0.9 * (1 - e))
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    final r = math.Random(dropSeed);
    final k = size > 70 ? 7 : 5;
    for (var i = 0; i < k; i++) {
      final ang = i / k * math.pi * 2 + r.nextDouble() * 0.6;
      final d = size * (0.55 + r.nextDouble() * 0.45);
      final s = 4 + r.nextDouble() * 5;
      final dur = 420 + r.nextDouble() * 180;
      if (dt >= dur) continue;
      final e = _drop.transform(dt / dur);
      final p = center + Offset(math.cos(ang) * d * e, (math.sin(ang) * d + 18) * e);
      c.drawCircle(p, s / 2 * (1 - 0.6 * e), Paint()..color = rim.withValues(alpha: 1 - e));
    }
  }

  /// The sparkle shape: clip-path polygon(50% 0, 61% 39%, 100% 50%, ...).
  static Path sparkle(double s) => Path()
    ..moveTo(0, -s / 2)
    ..lineTo(0.11 * s, -0.11 * s)
    ..lineTo(s / 2, 0)
    ..lineTo(0.11 * s, 0.11 * s)
    ..lineTo(0, s / 2)
    ..lineTo(-0.11 * s, 0.11 * s)
    ..lineTo(-s / 2, 0)
    ..lineTo(-0.11 * s, -0.11 * s)
    ..close();

  void _sparkles(Canvas c, Size size) {
    final r = math.Random(seed);
    final count = kind == DeniaSwitchKind.leave ? 4 : (kind.isForm ? 7 : 12);
    final dark = kind.dark;
    final fill = dark ? const Color(0xFFF3E9F7) : const Color(0xFFFFFFFF);
    final glow = dark
        ? const Color.fromRGBO(201, 139, 255, .95)
        : const Color.fromRGBO(255, 190, 225, .9);
    for (var i = 0; i < count; i++) {
      final x = (0.04 + r.nextDouble() * 0.92) * size.width;
      final y = (0.06 + r.nextDouble() * 0.8) * size.height;
      final s = 10 + r.nextDouble() * 16;
      final dur = 520 + r.nextDouble() * 300;
      final delay = r.nextDouble() * (plan.popTo - 300);
      final u = (t - delay) / dur;
      if (u <= 0 || u >= 1) continue;
      final half = u < 0.5 ? u / 0.5 : (1 - u) / 0.5;
      final k = Curves.easeInOut.transform(half.clamp(0.0, 1.0));
      final spin =
          (u < 0.5
              ? Curves.easeInOut.transform(u / 0.5)
              : 1 + Curves.easeInOut.transform((u - 0.5) / 0.5)) *
          math.pi /
          4;
      c.save();
      c.translate(x + s / 2, y + s / 2);
      c.rotate(spin);
      c.scale(k);
      final path = sparkle(s);
      c.drawPath(
        path,
        Paint()
          ..color = glow.withValues(alpha: glow.a * k)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, dark ? 5 : 4),
      );
      c.drawPath(path, Paint()..color = fill.withValues(alpha: k));
      c.restore();
    }
  }

  @override
  bool shouldRepaint(DeniaBubblesPainter old) => old.t != t;
}

/// The card in the middle of the switch (deniaSwitch.ts:93-108): Denia's sticker and a pill,
/// "Denia · Stagecraft" (Light) or "Denia · Breakdown" (Dark). It bounces in when the theme
/// changes and pops away with the bubbles.
class DeniaCard extends StatelessWidget {
  const DeniaCard({super.key, required this.t, required this.plan, required this.dark});

  final double t;
  final DeniaPlan plan;
  final bool dark;

  static int inAt(DeniaPlan p) => math.max(0, p.applyAt - 220);
  static int outAt(DeniaPlan p) => p.popTo - 120;

  static const _bounce = Cubic(0.2, 0.8, 0.3, 1.2);

  /// Scale, rotation (degrees) and opacity at [t] ms.
  static (double, double, double) poseAt(double t, DeniaPlan p) {
    final a = inAt(p).toDouble(), b = outAt(p).toDouble();
    if (t < a) return (0.3, -8, 0);
    if (t < a + 200) {
      final e = _bounce.transform((t - a) / 200);
      return (0.3 + 0.78 * e, -8 + 11 * e, e.clamp(0.0, 1.0));
    }
    if (t < a + 330) {
      final e = (t - a - 200) / 130;
      return (1.08 - 0.08 * e, 3 - 3 * e, 1);
    }
    if (t < b) return (1, 0, 1);
    if (t < b + 160) {
      final e = Curves.easeIn.transform((t - b) / 160);
      return (1 + 0.18 * e, 0, 1 - e);
    }
    return (1.18, 0, 0);
  }

  @override
  Widget build(BuildContext context) {
    final (scale, deg, opacity) = poseAt(t, plan);
    if (opacity <= 0) return const SizedBox.shrink();
    final vmin = MediaQuery.sizeOf(context).shortestSide;
    final art = DeniaArtCatalog.switchArt(dark: dark);
    return Center(
      child: Opacity(
        opacity: opacity,
        child: Transform.rotate(
          angle: deg * math.pi / 180,
          child: Transform.scale(
            scale: scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  art.asset,
                  width: math.min(240, vmin * 0.36),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                const SizedBox(height: 6),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color.fromRGBO(37, 24, 51, .92)
                        : const Color.fromRGBO(255, 255, 255, .92),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: dark ? const Color(0xFFC98BFF) : const Color(0xFFE58FB6),
                      width: 1.5,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    child: Text(
                      dark ? 'Denia · Breakdown' : 'Denia · Stagecraft',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                        color: dark ? const Color(0xFFF3E9F7) : const Color(0xFF8A3559),
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
