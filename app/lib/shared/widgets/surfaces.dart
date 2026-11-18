import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

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
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: shape, boxShadow: p.popoverShadow),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tint ?? p.shell,
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
    this.padding = const EdgeInsets.all(Spacing.xl),
  });

  final Widget child;
  final String? title;
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
    final p = AppPalette.of(context);
    final theme = Theme.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final lifted = _hovered && widget.onTap != null && !still;
    final shape = BorderRadius.circular(Radii.lg);
    final edge = _focused
        ? Border.all(color: p.ink, width: 2)
        : (p.hairline == null ? null : Border.all(color: p.hairline!));

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
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(widget.title!, style: theme.textTheme.titleLarge),
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
      body = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: shape,
          onHover: (v) => setState(() => _hovered = v),
          onFocusChange: (v) => setState(() => _focused = v),
          child: body,
        ),
      );
      body = Semantics(button: true, label: widget.semanticLabel, child: body);
    }

    return AnimatedContainer(
      duration: still ? Duration.zero : Motion.fast,
      curve: Motion.curve,
      transform: Matrix4.translationValues(0, lifted ? -2 : 0, 0),
      decoration: BoxDecoration(
        color: widget.color ?? p.surface,
        borderRadius: shape,
        border: edge,
        boxShadow: lifted ? p.popoverShadow : p.cardShadow,
      ),
      child: body,
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
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? p.ink,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Icon(icon, size: size / 2, color: background == null ? p.onInk : p.ink),
    );
  }
}

/// A pastel card that starts something: icon chip, title, one-line description and an
/// optional badge ("Last used").
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
  final VoidCallback onTap;
  final String? badge;

  /// A muted last line ("You need: a recorded video file").
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return AppCard(
      color: color,
      onTap: onTap,
      semanticLabel: [title, description, ?badge].join('. '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconChip(icon: icon),
              const Spacer(),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 2),
                  decoration: BoxDecoration(
                    color: p.surface.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Text(badge!, style: text.labelMedium),
                ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          Text(title, style: text.titleLarge),
          const SizedBox(height: Spacing.xs),
          Text(description, style: text.bodyMedium?.copyWith(color: p.text2)),
          if (footnote != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(footnote!, style: text.bodySmall),
          ],
        ],
      ),
    );
  }
}
