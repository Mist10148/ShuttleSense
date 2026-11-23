import 'package:flutter/material.dart';

// ======================================================================================
// DEPTH KIT (copy this section into your app)
// ======================================================================================

@immutable
class DepthTheme extends ThemeExtension<DepthTheme> {
  const DepthTheme({
    required this.page,
    required this.bg,
    required this.well,
    required this.shade,
    required this.hi,
    required this.accent,
    required this.good,
    required this.warn,
    required this.bad,
    required this.ink,
    required this.muted,
  });

  final Color page, bg, well, shade, hi, accent, good, warn, bad, ink, muted;

  // Adjust ONLY these colours to your palette. page and bg must differ slightly and
  // neither may be pure white or pure black, or the highlight/shadow disappears.
  static const light = DepthTheme(
    page: Color(0xFFCDD5E2),
    bg: Color(0xFFEEF2F8),
    well: Color(0xFFDDE3EC),
    shade: Color(0xFF1E2D50),
    hi: Color(0xFFFFFFFF),
    accent: Color(0xFF3F72AF),
    good: Color(0xFF1D7A50),
    warn: Color(0xFF8A5205),
    bad: Color(0xFFA82C2C),
    ink: Color(0xFF112D4E),
    muted: Color(0xFF4A5D78),
  );

  static const dark = DepthTheme(
    page: Color(0xFF1F2125),
    bg: Color(0xFF2A2D32),
    well: Color(0xFF1A1C1F),
    shade: Color(0xFF000000),
    hi: Color(0xFFFFFFFF),
    accent: Color(0xFF8CB0E0),
    good: Color(0xFF5CC896),
    warn: Color(0xFFE6A54A),
    bad: Color(0xFFF07B7B),
    ink: Color(0xFFECEDEF),
    muted: Color(0xFF9EA2AA),
  );

  @override
  DepthTheme copyWith({
    Color? page,
    Color? bg,
    Color? well,
    Color? shade,
    Color? hi,
    Color? accent,
    Color? good,
    Color? warn,
    Color? bad,
    Color? ink,
    Color? muted,
  }) => DepthTheme(
    page: page ?? this.page,
    bg: bg ?? this.bg,
    well: well ?? this.well,
    shade: shade ?? this.shade,
    hi: hi ?? this.hi,
    accent: accent ?? this.accent,
    good: good ?? this.good,
    warn: warn ?? this.warn,
    bad: bad ?? this.bad,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
  );

  @override
  DepthTheme lerp(ThemeExtension<DepthTheme>? other, double t) => this;
}

extension DepthContext on BuildContext {
  DepthTheme get depth => Theme.of(this).extension<DepthTheme>()!;
  bool get isDarkDepth => Theme.of(this).brightness == Brightness.dark;
}

/// Paints inner shadows (Flutter has no inset BoxShadow), clipped to the rounded rect.
/// Each shadow's offset is where the shadow falls INSIDE the box.
class InsetShadowPainter extends CustomPainter {
  InsetShadowPainter({required this.radius, required this.shadows, this.fill, this.borderColor});
  final double radius;
  final List<BoxShadow> shadows;
  final Color? fill; // painted first, so the shadows sit ON the fill and the child sits on top
  final Color? borderColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    if (fill != null) canvas.drawRRect(rrect, Paint()..color = fill!);
    canvas.save();
    canvas.clipRRect(rrect);
    for (final s in shadows) {
      // Even-odd fill: the big rect minus the shifted rounded rect leaves a ring. (Path.combine
      // with PathOperation.difference flooded the whole box on some backends.)
      final ring = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(80))
        ..addRRect(rrect.shift(s.offset));
      final paint = Paint()..color = s.color;
      // A zero-blur mask filter misbehaves on some backends: only blur when asked to.
      if (s.blurRadius > 0) paint.maskFilter = MaskFilter.blur(BlurStyle.normal, s.blurRadius / 2);
      canvas.drawPath(ring, paint);
    }
    canvas.restore();
    if (borderColor != null) {
      canvas.drawRRect(
        rrect.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = borderColor!,
      );
    }
  }

  @override
  bool shouldRepaint(InsetShadowPainter old) =>
      old.radius != radius ||
      old.shadows != shadows ||
      old.fill != fill ||
      old.borderColor != borderColor;
}

/// A recessed box (a "well"): icon wells, value slots, progress tracks.
class InsetBox extends StatelessWidget {
  const InsetBox({
    super.key,
    this.child,
    this.radius = 12,
    this.padding,
    this.width,
    this.height,
    this.fill,
    this.strength = 1.0,
  });

  final Widget? child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double? width, height;
  final Color? fill;
  final double strength;

  @override
  Widget build(BuildContext context) {
    final d = context.depth;
    final dark = context.isDarkDepth;
    final dk = d.shade.withValues(alpha: (dark ? 0.55 : 0.20) * strength);
    final lt = d.hi.withValues(alpha: dark ? 0.06 : 0.90);
    return RepaintBoundary(
      child: CustomPaint(
        painter: InsetShadowPainter(
          radius: radius,
          fill: fill ?? d.well,
          shadows: [
            BoxShadow(color: dk, offset: const Offset(2.5, 2.5), blurRadius: 5),
            BoxShadow(color: lt, offset: const Offset(-2.5, -2.5), blurRadius: 5),
          ],
        ),
        // No decoration on the Container: it would paint over the inner shadows.
        child: Container(width: width, height: height, padding: padding, child: child),
      ),
    );
  }
}

/// Raised box (card): gradient face, 1px edge, dark shadow bottom-right + light top-left.
/// Do NOT wrap it in ClipRRect: that would cut the outer shadows off.
class DepthCard extends StatelessWidget {
  const DepthCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 18,
    this.selected = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final d = context.depth;
    final dark = context.isDarkDepth;
    Widget body;
    if (selected) {
      // Pushed-in state: recessed, with an accent edge on the left.
      body = CustomPaint(
        painter: InsetShadowPainter(
          radius: radius,
          fill: d.well,
          borderColor: d.shade.withValues(alpha: 0.08),
          shadows: [
            BoxShadow(
              color: d.shade.withValues(alpha: dark ? 0.55 : 0.18),
              offset: const Offset(3, 3),
              blurRadius: 7,
            ),
            BoxShadow(
              color: d.hi.withValues(alpha: dark ? 0.05 : 0.8),
              offset: const Offset(-3, -3),
              blurRadius: 7,
            ),
            BoxShadow(color: d.accent, offset: const Offset(3, 0), blurRadius: 0),
          ],
        ),
        child: Container(padding: padding, child: child),
      );
    } else {
      body = Container(
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              d.bg,
              Color.alphaBlend(d.shade.withValues(alpha: dark ? 0.0 : 0.04), d.bg),
            ],
          ),
          border: Border.all(color: d.shade.withValues(alpha: 0.08)),
          boxShadow: [
            BoxShadow(
              color: d.shade.withValues(alpha: dark ? 0.65 : 0.22),
              offset: const Offset(7, 9),
              blurRadius: 18,
              spreadRadius: -6,
            ),
            BoxShadow(
              color: d.hi.withValues(alpha: dark ? 0.03 : 0.85),
              offset: const Offset(-5, -5),
              blurRadius: 14,
            ),
          ],
        ),
        child: child,
      );
    }
    return RepaintBoundary(
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: body),
    );
  }
}

enum IconTone { neutral, active, good, warn, bad }

/// An icon sitting in a recessed well (raised accent chip when active).
/// The glyph stays flat. Use one size per list.
class IconWell extends StatelessWidget {
  const IconWell({
    super.key,
    required this.icon,
    this.size = 34,
    this.iconSize = 18,
    this.tone = IconTone.neutral,
    this.round = false,
  });

  final IconData icon;
  final double size, iconSize;
  final IconTone tone;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final d = context.depth;
    final dark = context.isDarkDepth;
    final r = round ? size / 2 : size * 0.3;
    if (tone == IconTone.active) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [d.accent, Color.alphaBlend(Colors.black.withValues(alpha: 0.18), d.accent)],
          ),
          boxShadow: [
            BoxShadow(
              color: d.accent.withValues(alpha: 0.35),
              offset: const Offset(3, 4),
              blurRadius: 9,
            ),
            BoxShadow(
              color: d.hi.withValues(alpha: dark ? 0.04 : 0.8),
              offset: const Offset(-2, -2),
              blurRadius: 6,
            ),
          ],
        ),
        child: Icon(icon, size: iconSize, color: Colors.white),
      );
    }
    final Color glyph = switch (tone) {
      IconTone.good => d.good,
      IconTone.warn => d.warn,
      IconTone.bad => d.bad,
      _ => d.accent,
    };
    final Color fill = switch (tone) {
      IconTone.good => Color.alphaBlend(d.good.withValues(alpha: dark ? 0.16 : 0.14), d.well),
      IconTone.warn => Color.alphaBlend(d.warn.withValues(alpha: dark ? 0.16 : 0.14), d.well),
      IconTone.bad => Color.alphaBlend(d.bad.withValues(alpha: dark ? 0.16 : 0.14), d.well),
      _ => d.well,
    };
    return InsetBox(
      width: size,
      height: size,
      radius: r,
      fill: fill,
      child: Center(
        child: Icon(icon, size: iconSize, color: glyph),
      ),
    );
  }
}

/// Recessed cell for one figure inside a card: label above value.
class DepthSlot extends StatelessWidget {
  const DepthSlot({super.key, required this.label, required this.value});
  final Widget label, value;

  @override
  Widget build(BuildContext context) => InsetBox(
    radius: 12,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [label, const SizedBox(height: 2), value],
    ),
  );
}

/// Engraved divider: a dark line with a white line right under it.
class DepthGroove extends StatelessWidget {
  const DepthGroove({super.key, this.margin = const EdgeInsets.symmetric(vertical: 12)});
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final d = context.depth;
    final dark = context.isDarkDepth;
    return Padding(
      padding: margin,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(height: 1, color: d.shade.withValues(alpha: dark ? 0.6 : 0.14)),
          Container(height: 1, color: d.hi.withValues(alpha: dark ? 0.05 : 0.9)),
        ],
      ),
    );
  }
}

/// Recessed progress track; the fill stays your accent colour.
class DepthTrack extends StatelessWidget {
  const DepthTrack({super.key, required this.value, this.height = 9});
  final double value; // 0..1
  final double height;

  @override
  Widget build(BuildContext context) {
    final d = context.depth;
    return InsetBox(
      height: height,
      radius: height / 2,
      strength: 1.1,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value.clamp(0.0, 1.0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(height / 2),
              color: d.accent,
            ),
          ),
        ),
      ),
    );
  }
}
