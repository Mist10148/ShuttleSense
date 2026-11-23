import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../ui/depth.dart';
import 'tactile.dart';

/// The page canvas: a base colour with three soft glows (lavender, peach, mint in light mode;
/// faint green and violet in dark mode).
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  static const _glowCentres = [Alignment(-0.9, -1), Alignment(1, -0.6), Alignment(0.6, 1.1)];

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: p.canvas),
      child: Stack(
        children: [
          for (final (i, glow) in p.canvasGlows.indexed)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: _glowCentres[i % _glowCentres.length],
                    radius: 1.1,
                    colors: [glow, glow.withValues(alpha: 0)],
                  ),
                ),
              ),
            ),
          Positioned.fill(child: child),
        ],
      ),
    );
  }
}

/// Frosted, translucent panel: the floating app shell and the panels over live video.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = Radii.xl,
    this.padding = EdgeInsets.zero,
    this.tint,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Replaces the default glass fill, e.g. a pink tint for the offline banner.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final shape = BorderRadius.circular(radius);
    if (tint == null) {
      // The app body: an opaque moulded chassis, lit from the top left.
      final t = TactileTokens.of(context);
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [t.chassisTop, t.chassisBottom],
          ),
          border: Border.all(color: t.rim),
          boxShadow: p.popoverShadow,
        ),
        child: ClipRRect(
          borderRadius: shape,
          child: Padding(padding: padding, child: child),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: shape, boxShadow: p.popoverShadow),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tint,
              borderRadius: shape,
              border: Border.all(color: p.hairline ?? p.surface.withValues(alpha: 0.6)),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// The standard card: an optional title row (title, subtitle, actions, an expand ↗ button)
/// over [child]. With [onTap] the whole card is a button that lifts on hover and shows a
/// focus ring for keyboard users.
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.onExpand,
    this.onTap,
    this.semanticLabel,
    this.color,
    this.icon,
    this.padding = const EdgeInsets.all(Spacing.xl),
  });

  final Widget child;
  final String? title;

  /// A small icon in a sunken well before the title.
  final IconData? icon;
  final String? subtitle;
  final List<Widget> actions;
  final VoidCallback? onExpand;
  final VoidCallback? onTap;

  /// What a screen reader says for a tappable card.
  final String? semanticLabel;

  /// A pastel fill instead of the surface colour.
  final Color? color;
  final EdgeInsetsGeometry padding;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final theme = Theme.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final lifted = _hovered && widget.onTap != null && !still;
    final shape = BorderRadius.circular(Radii.lg);
    // Hovering a tappable card lights its whole edge, not just the part under the pointer.
    final edge = _focused
        ? Border.all(color: t.primary, width: 2)
        : Border.all(
            color: lifted
                ? t.primary.withValues(alpha: 0.4)
                : (t.flat ? t.rim : Colors.transparent),
            width: 2,
          );

    Widget body = Padding(
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.title != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.icon != null) ...[
                  // The header icon sits in a recessed well (lib/ui/depth.dart).
                  IconWell(icon: widget.icon!, size: 36, iconSize: 18),
                  const SizedBox(width: Spacing.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          widget.title!,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      if (widget.subtitle != null)
                        Text(widget.subtitle!, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                ...widget.actions,
                if (widget.onExpand != null)
                  IconButton(
                    onPressed: widget.onExpand,
                    tooltip: 'Expand',
                    icon: const Icon(Icons.north_east, size: 20),
                  ),
              ],
            ),
            const SizedBox(height: Spacing.lg),
          ],
          widget.child,
        ],
      ),
    );

    if (widget.onTap != null) {
      body = Semantics(
        button: true,
        label: widget.semanticLabel,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: shape,
          splashFactory: NoSplash.splashFactory,
          hoverColor: Colors.transparent,
          highlightColor: t.recess.withValues(alpha: 0.25),
          focusColor: Colors.transparent,
          onHover: (v) => setState(() => _hovered = v),
          onFocusChange: (v) => setState(() => _focused = v),
          child: body,
        ),
      );
    }
    // Ripples of the card and of list tiles inside it paint on this layer, above the fill.
    body = Material(type: MaterialType.transparency, child: body);

    // Its own layer: the hover lift and its shadow animate without redrawing the rest of
    // the page (the mouse crosses cards while scrolling). Looks exactly the same.
    return RepaintBoundary(
      child: AnimatedContainer(
        duration: still ? Duration.zero : Motion.fast,
        curve: Motion.curve,
        transform: Matrix4.translationValues(0, lifted ? -3 : 0, 0),
        decoration: BoxDecoration(
          gradient: widget.color == null ? convexGradient(t) : raisedGradient(t, widget.color),
          borderRadius: shape,
          border: edge,
          boxShadow: [...raisedShadows(t, depth: lifted ? 1.3 : 1)],
        ),
        child: CustomPaint(
          foregroundPainter: BevelPainter(
            radius: Radii.lg,
            light: bevelColors(context).$1,
            dark: bevelColors(context).$2,
          ),
          child: body,
        ),
      ),
    );
  }
}

/// A rounded-square icon holder: ink with a light icon by default, or a pastel [background]
/// with an ink icon.
class IconChip extends StatelessWidget {
  const IconChip({super.key, required this.icon, this.background, this.size = 40});

  final IconData icon;
  final Color? background;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final t = TactileTokens.of(context);
    final tint = background;
    if (tint != null) {
      // A small well pressed into the surface, tinted by the pastel, with the icon in a
      // deeper shade of the same colour.
      final hsl = HSLColor.fromColor(tint);
      final dark = Theme.of(context).brightness == Brightness.dark;
      final iconColor = tint == p.surface || tint == p.surface2
          ? p.text2
          : hsl
                .withSaturation((hsl.saturation * 1.2).clamp(0.35, 0.75))
                .withLightness(dark ? 0.72 : 0.38)
                .toColor();
      return Recess(
        radius: size * 0.3,
        padding: EdgeInsets.zero,
        depth: 2.5,
        color: Color.lerp(t.recess, tint, dark ? 0.35 : 0.55),
        child: SizedBox.square(
          dimension: size,
          child: Icon(icon, size: size * 0.48, color: iconColor),
        ),
      );
    }
    // Without a tint: a small raised ink key with a light icon.
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(p.ink, Colors.white, 0.18)!, p.ink],
        ),
        borderRadius: BorderRadius.circular(Radii.md),
        boxShadow: chipShadows(t),
      ),
      child: Icon(icon, size: size / 2, color: p.onInk),
    );
  }
}

/// A pastel card that starts something: icon chip, title, one-line description and an
/// optional badge ("Last used"). Without [onTap] it is unavailable: a neutral fill, no button,
/// text still at full contrast so the reason in [description] stays readable.
class PastelActionCard extends StatelessWidget {
  const PastelActionCard({
    super.key,
    required this.color,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.badge,
    this.footnote,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback? onTap;
  final String? badge;

  /// A muted last line ("You need: a recorded video file").
  final String? footnote;

  bool get enabled => onTap != null;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final t = TactileTokens.of(context);
    // Icon well and badge on top, then the title and description: a key you can read at a
    // glance, sized a little smaller than a full card.
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconWell(icon: icon, size: 44, iconSize: 22),
            const Spacer(),
            if (badge != null)
              Flexible(
                flex: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: primaryGradient(t),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    badge!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium?.copyWith(
                      color: t.onPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text(title, style: text.titleLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(description, style: text.bodyMedium?.copyWith(color: p.text2)),
        if (footnote != null) ...[
          const SizedBox(height: Spacing.sm),
          Text(footnote!, style: text.bodySmall),
        ],
      ],
    );
    return KeyCap(
      onTap: onTap,
      ring: badge != null && enabled ? t.primary.withValues(alpha: 0.7) : null,
      semanticLabel: [title, description, ?badge].join('. '),
      padding: const EdgeInsets.all(20),
      child: content,
    );
  }
}

/// Lays [children] out in as many equal columns as fit at [minWidth] each, up to
/// [maxColumns]: three on a laptop, two on a tablet, one on a phone.
class CardGrid extends StatelessWidget {
  const CardGrid({super.key, required this.children, this.minWidth = 340, this.maxColumns = 3});

  final List<Widget> children;
  final double minWidth;
  final int maxColumns;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns = (box.maxWidth / minWidth).floor().clamp(1, maxColumns);
      final width = (box.maxWidth - Spacing.lg * (columns - 1)) / columns;
      return Wrap(
        spacing: Spacing.lg,
        runSpacing: Spacing.lg,
        children: [for (final c in children) SizedBox(width: width, child: c)],
      );
    },
  );
}
