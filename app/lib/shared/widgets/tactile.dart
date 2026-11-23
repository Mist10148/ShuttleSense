import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../ui/depth.dart';

/// The depth scale. One light source (top left), four levels, every surface composes from it:
/// - [Depth.recessed] (0): fields, wells, tracks, trays. Inner shade top left, lip of light
///   bottom right ([Recess], [InsetPainter]).
/// - [Depth.raised] (1): chips, secondary buttons, small tiles ([chipShadows]).
/// - [Depth.raisedHigh] (2): cards and panels, primary buttons, KPI tiles
///   ([raisedShadows]).
/// - [Depth.floating] (3): menus, dialogs, sheets, tooltips, toasts (the theme's
///   elevations, see app_theme.dart).
/// Pressed parts sink to level 0; hovered parts lift one step. Never more than 3 shadows.
enum Depth { recessed, raised, raisedHigh, floating }

/// The outer shadows of [level] (none for [Depth.recessed], which is drawn inside).
List<BoxShadow> depthShadows(TactileTokens t, Depth level, {bool hovered = false}) =>
    switch (level) {
      Depth.recessed => const [],
      Depth.raised => chipShadows(t, hovered: hovered),
      Depth.raisedHigh => raisedShadows(t, depth: hovered ? 1.3 : 1),
      Depth.floating => [
        BoxShadow(color: t.shade, blurRadius: 40, offset: const Offset(0, 18)),
        BoxShadow(color: t.shade, blurRadius: 8, offset: const Offset(0, 3)),
      ],
    };

/// The outer shadows of a raised panel: a soft shade falling to the bottom right and a light
/// bloom to the top left, so the plate reads as pushed out of the surface.
List<BoxShadow> raisedShadows(TactileTokens t, {double depth = 1}) => [
  BoxShadow(color: t.shade, blurRadius: 30 * depth, offset: Offset(13 * depth, 13 * depth)),
  BoxShadow(
    color: t.highlight.withValues(alpha: t.highlight.a * 0.55),
    blurRadius: 16 * depth,
    offset: Offset(-6 * depth, -6 * depth),
  ),
];

/// The tighter shadows of small raised parts (chips, buttons, keys); [hovered] lifts them.
List<BoxShadow> chipShadows(TactileTokens t, {bool hovered = false}) => [
  BoxShadow(
    color: t.shade,
    blurRadius: hovered ? 18 : 12,
    offset: Offset(hovered ? 8 : 5, hovered ? 8 : 5),
  ),
  BoxShadow(
    color: t.highlight.withValues(alpha: t.highlight.a * 0.6),
    blurRadius: hovered ? 10 : 7,
    offset: Offset(hovered ? -4 : -3, hovered ? -4 : -3),
  ),
];

/// The main action's fill: steel blue, deepening towards the bottom.
Gradient primaryGradient(TactileTokens t) => LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [t.primary, t.primaryDeep],
);

/// The solid fill of a moulded panel: the ground tone, swelling towards the light at the top
/// left and away from it at the bottom right, so the plate reads as convex.
Gradient convexGradient(TactileTokens t) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [t.raisedTop, t.raisedBottom],
);

/// How a tactile button moves: up 1 px under the pointer, down to 97% while pressed.
Matrix4 buttonMotion(Set<WidgetState> states, {required bool still}) {
  if (still || states.contains(WidgetState.disabled)) return Matrix4.identity();
  if (states.contains(WidgetState.pressed)) {
    return Matrix4.diagonal3Values(0.97, 0.97, 1);
  }
  if (states.contains(WidgetState.hovered)) return Matrix4.translationValues(0, -1, 0);
  return Matrix4.identity();
}

/// The kinds of button in the tactile theme.
enum TactileButtonKind {
  /// Steel-blue gradient key with white text: the one main action of a view.
  primary,

  /// Raised light chip with a thin edge: every other button.
  secondary,

  /// No fill until hovered, then a faint well: inline text actions.
  ghost,
}

/// Paints a button of [kind] for [states] behind its content and animates between states:
/// raised at rest, lifted with a longer shadow on hover, sunk into a well while pressed.
/// Used by the button themes, so every Material button in the app gets the same feel.
class TactileButtonSurface extends StatelessWidget {
  const TactileButtonSurface({
    super.key,
    required this.kind,
    required this.states,
    required this.radius,
    this.child,
  });

  final TactileButtonKind kind;
  final Set<WidgetState> states;
  final double radius;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final disabled = states.contains(WidgetState.disabled);
    final pressed = states.contains(WidgetState.pressed);
    final hovered = states.contains(WidgetState.hovered) && !pressed;
    final focused = states.contains(WidgetState.focused);
    final shape = BorderRadius.circular(radius);

    BoxDecoration decoration;
    if (disabled) {
      decoration = BoxDecoration(
        color: kind == TactileButtonKind.ghost ? null : t.recess.withValues(alpha: 0.6),
        borderRadius: shape,
      );
    } else {
      switch (kind) {
        case TactileButtonKind.primary:
          // A pressable blue key: a face lit from the top that deepens towards the bottom,
          // a bevel (light top edge, dark bottom edge, painted below) and a soft coloured
          // shadow that grows on hover.
          decoration = BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.55, 1],
              colors: pressed
                  ? [t.primaryDeep, t.primaryDeep, t.primaryDeep]
                  : [
                      Color.lerp(t.primary, Colors.white, hovered ? 0.08 : 0.04)!,
                      t.primary,
                      t.primaryDeep,
                    ],
            ),
            borderRadius: shape,
            boxShadow: pressed
                ? [
                    BoxShadow(
                      color: t.primaryDeep.withValues(alpha: 0.35),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : [
                    BoxShadow(
                      color: t.primaryDeep.withValues(alpha: hovered ? 0.45 : 0.35),
                      blurRadius: hovered ? 20 : 14,
                      offset: Offset(0, hovered ? 8 : 6),
                    ),
                    BoxShadow(
                      color: t.primaryDeep.withValues(alpha: 0.3),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
          );
        case TactileButtonKind.secondary:
          // A light key that stands clear of the card: a top-lit face, a fine edge and a
          // short drop shadow, so it does not melt into the surface behind it.
          final dark = Theme.of(context).brightness == Brightness.dark;
          final edge = t.flat
              ? t.rim
              : (dark
                    ? Colors.white.withValues(alpha: 0.08)
                    : const Color(0xFF112D4E).withValues(alpha: 0.14));
          decoration = BoxDecoration(
            gradient: pressed ? null : raisedGradient(t),
            color: pressed ? t.recess : null,
            borderRadius: shape,
            border: Border.all(color: hovered ? t.primary.withValues(alpha: 0.45) : edge),
            boxShadow: pressed
                ? null
                : [
                    BoxShadow(
                      color: t.shade,
                      blurRadius: hovered ? 14 : 8,
                      offset: Offset(0, hovered ? 6 : 3),
                    ),
                    BoxShadow(
                      color: t.highlight.withValues(alpha: t.highlight.a * 0.8),
                      blurRadius: 6,
                      offset: const Offset(-2, -2),
                    ),
                  ],
          );
        case TactileButtonKind.ghost:
          decoration = BoxDecoration(
            color: pressed ? t.recess : (hovered ? t.recess.withValues(alpha: 0.55) : null),
            borderRadius: shape,
          );
      }
    }
    if (focused) {
      decoration = decoration.copyWith(border: Border.all(color: t.primary, width: 2));
    }

    final (bevelLight, bevelDark) = bevelColors(context);
    final raised = !disabled && !pressed && kind != TactileButtonKind.ghost;
    Widget surface = AnimatedContainer(
      duration: still ? Duration.zero : Duration(milliseconds: pressed ? 60 : 160),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      decoration: decoration,
      child: CustomPaint(
        foregroundPainter: raised
            ? (kind == TactileButtonKind.primary
                  ? _TopLightPainter(radius: radius)
                  : BevelPainter(radius: radius, light: bevelLight, dark: bevelDark))
            : null,
        child: child,
      ),
    );
    // A pressed secondary button sinks: an inner shadow along its top-left edge.
    if (pressed && kind != TactileButtonKind.primary && !disabled) {
      surface = CustomPaint(
        foregroundPainter: InsetPainter(
          radius: radius,
          fill: const LinearGradient(colors: [Colors.transparent, Colors.transparent]),
          shade: t.innerShade,
          light: t.innerLight,
          depth: 2.5,
        ),
        child: surface,
      );
    }
    return AnimatedContainer(
      duration: still ? Duration.zero : Duration(milliseconds: pressed ? 60 : 160),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      transform: buttonMotion(states, still: still),
      transformAlignment: Alignment.center,
      child: surface,
    );
  }
}

/// A ButtonStyle whose background is a [TactileButtonSurface] of [kind].
ButtonStyle tactileButtonStyle(TactileButtonKind kind, {double radius = 12}) => ButtonStyle(
  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
  overlayColor: const WidgetStatePropertyAll(Colors.transparent),
  shadowColor: const WidgetStatePropertyAll(Colors.transparent),
  surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
  elevation: const WidgetStatePropertyAll(0),
  side: const WidgetStatePropertyAll(BorderSide.none),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
  ),
  splashFactory: NoSplash.splashFactory,
  backgroundBuilder: (context, states, child) =>
      TactileButtonSurface(kind: kind, states: states, radius: radius, child: child),
);

/// A segment of a segmented control: the row sits in a shallow well and the chosen segment
/// is a raised chip inside it.
ButtonStyle tactileSegmentStyle({double radius = 12}) => ButtonStyle(
  backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
  overlayColor: const WidgetStatePropertyAll(Colors.transparent),
  side: const WidgetStatePropertyAll(BorderSide.none),
  elevation: const WidgetStatePropertyAll(0),
  splashFactory: NoSplash.splashFactory,
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
  ),
  backgroundBuilder: (context, states, child) {
    final t = TactileTokens.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final selected = states.contains(WidgetState.selected);
    final hovered = states.contains(WidgetState.hovered);
    return ColoredBox(
      color: t.recess,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: AnimatedContainer(
          duration: still ? Duration.zero : const Duration(milliseconds: 180),
          curve: const Cubic(0.2, 0.8, 0.2, 1),
          decoration: BoxDecoration(
            gradient: selected ? raisedGradient(t) : null,
            color: selected ? null : (hovered ? t.raisedTop.withValues(alpha: 0.35) : null),
            borderRadius: BorderRadius.circular(radius - 3),
            boxShadow: selected ? chipShadows(t) : null,
          ),
          child: child,
        ),
      ),
    );
  },
);

/// The fill of a raised part: a top-lit gradient of [color], or of the neutral plate tones.
Gradient raisedGradient(TactileTokens t, [Color? color]) => LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: color == null
      ? [t.raisedTop, t.raisedBottom]
      : [Color.lerp(color, Colors.white, t.capSheen)!, color],
);

/// Paints a sunken surface: the fill, then an inner shadow along the top-left edge and an
/// inner lip of light along the bottom-right edge. Flutter's BoxShadow has no inset option,
/// so this is the one custom primitive of the tactile layer.
class InsetPainter extends CustomPainter {
  const InsetPainter({
    required this.radius,
    required this.fill,
    required this.shade,
    required this.light,
    this.depth = 4,
  });

  final double radius;
  final Gradient fill;
  final Color shade;
  final Color light;
  final double depth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(rrect, Paint()..shader = fill.createShader(rect));
    canvas
      ..save()
      ..clipRRect(rrect);
    void ring(Color color, Offset shift) {
      final outer = Path()..addRect(rect.inflate(depth * 4));
      final hole = Path()..addRRect(rrect.shift(shift));
      canvas.drawPath(
        Path.combine(PathOperation.difference, outer, hole),
        Paint()
          ..color = color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, depth),
      );
    }

    ring(shade, Offset(depth * 0.6, depth * 0.8));
    ring(light, Offset(-depth * 0.5, -depth * 0.6));
    canvas.restore();
  }

  @override
  bool shouldRepaint(InsetPainter old) =>
      old.radius != radius ||
      old.fill != fill ||
      old.shade != shade ||
      old.light != light ||
      old.depth != depth;
}

/// A sunken well: search slots, stat tiles, tracks, trays.
class Recess extends StatelessWidget {
  const Recess({
    super.key,
    required this.child,
    this.radius = Radii.md,
    this.padding = const EdgeInsets.all(Spacing.md),
    this.color,
    this.depth = 6,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// A tinted well instead of the neutral recess tone.
  final Color? color;
  final double depth;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final c = color ?? t.recess;
    if (t.flat) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: t.rim),
        ),
        child: Padding(padding: padding, child: child),
      );
    }
    return CustomPaint(
      painter: InsetPainter(
        radius: radius,
        fill: LinearGradient(colors: [c, c]),
        shade: t.innerShade,
        light: t.innerLight,
        depth: depth,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// An inset display: holds the court, the speed dial and other drawings. Lighter than a
/// recess and with a faint glass sheen across its top-left corner.
class InsetScreen extends StatelessWidget {
  const InsetScreen({
    super.key,
    required this.child,
    this.radius = Radii.md,
    this.padding = const EdgeInsets.all(Spacing.md),
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: InsetPainter(
        radius: radius,
        fill: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [t.screenTop, t.screenBottom],
        ),
        shade: t.innerShade,
        light: t.innerLight,
        depth: 5,
      ),
      foregroundPainter: _SheenPainter(radius, dark ? 0.05 : 0.45),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _SheenPainter extends CustomPainter {
  const _SheenPainter(this.radius, this.strength);

  final double radius;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: const Alignment(0, 0.2),
          colors: [
            Colors.white.withValues(alpha: strength),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SheenPainter old) => old.radius != radius || old.strength != strength;
}

/// A moulded plate that stands off the chassis: cards and panels.
class Raised extends StatelessWidget {
  const Raised({
    super.key,
    required this.child,
    this.radius = Radii.lg,
    this.padding = EdgeInsets.zero,
    this.color,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// A pastel plate instead of the neutral one.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: color == null ? convexGradient(t) : raisedGradient(t, color),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: raisedShadows(t),
      ),
      child: CustomPaint(
        foregroundPainter: BevelPainter(
          radius: radius,
          light: bevelColors(context).$1,
          dark: bevelColors(context).$2,
        ),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A physical key: a cap on a visible base that sinks when pressed. [selected] latches it
/// down (a pressed rail button, a chosen segment). Without [onTap] it is drawn flat and
/// disabled. Keeps a 48 px minimum height and a 2 px focus ring for keyboard users.
class KeyCap extends StatefulWidget {
  const KeyCap({
    super.key,
    required this.child,
    required this.onTap,
    this.color,
    this.radius = Radii.lg,
    this.padding = const EdgeInsets.all(Spacing.lg),
    this.selected = false,
    this.semanticLabel,
    this.travel = 7,
    this.tooltip,
    this.ring,
  });

  /// An accent edge around the cap (the last-used mode), instead of the plain rim.
  final Color? ring;

  final Widget child;
  final VoidCallback? onTap;

  /// The cap colour: a pastel, or null for the neutral plate tone.
  final Color? color;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool selected;
  final String? semanticLabel;
  final String? tooltip;

  /// How far the key sinks when pressed, in logical pixels.
  final double travel;

  @override
  State<KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<KeyCap> {
  bool _down = false;
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final p = AppPalette.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onTap != null;
    final pressed = enabled && (_down || widget.selected);
    final capColor = widget.color ?? t.raisedBottom;
    final rise = !enabled ? 0.0 : (pressed ? 1.0 : widget.travel);
    final shape = BorderRadius.circular(widget.radius);

    Widget body = Padding(padding: widget.padding, child: widget.child);
    if (enabled) {
      body = Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: shape,
          splashFactory: NoSplash.splashFactory,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
          onHighlightChanged: (v) => setState(() => _down = v),
          onHover: (v) => setState(() => _hovered = v),
          onFocusChange: (v) => setState(() => _focused = v),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinTouchTarget),
            child: body,
          ),
        ),
      );
      body = Semantics(
        button: true,
        selected: widget.selected,
        label: widget.semanticLabel,
        excludeSemantics: widget.semanticLabel != null,
        child: body,
      );
    } else {
      body = Semantics(enabled: false, label: widget.semanticLabel, child: body);
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    final (bevelLight, bevelDark) = bevelColors(context);
    final hovered = enabled && _hovered && !pressed && !still;
    final lift = hovered ? -2.0 : 0.0;
    final squash = _down && !still ? 0.98 : 1.0;
    final cap = AnimatedContainer(
      duration: still ? Duration.zero : Duration(milliseconds: _down ? 60 : 180),
      curve: Motion.curve,
      transform: Matrix4.translationValues(0, widget.travel - rise + lift, 0)
        ..scaleByDouble(squash, squash, 1, 1),
      transformAlignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: enabled ? raisedGradient(t, capColor) : null,
        color: enabled ? null : p.surface2,
        borderRadius: shape,
        border: _focused
            ? Border.all(color: t.primary, width: 2)
            : Border.all(
                color: !enabled ? Colors.transparent : (widget.ring ?? t.rim),
                width: widget.ring == null ? 1 : 2,
              ),
        boxShadow: enabled
            ? [
                BoxShadow(color: t.edgeFor(capColor), offset: Offset(0, rise)),
                BoxShadow(
                  color: t.shade,
                  blurRadius: pressed ? 4 : (hovered ? 26 : 16),
                  offset: Offset(hovered ? 4 : 2, pressed ? 2 : rise + (hovered ? 12 : 6)),
                ),
                if (!pressed)
                  BoxShadow(color: t.highlight, blurRadius: 10, offset: const Offset(-3, -3)),
              ]
            : null,
      ),
      child: CustomPaint(
        painter: enabled && !pressed
            ? GlossPainter(radius: widget.radius, strength: dark ? 0.06 : 0.55)
            : null,
        foregroundPainter: enabled && !pressed
            ? BevelPainter(radius: widget.radius, light: bevelLight, dark: bevelDark)
            : null,
        child: body,
      ),
    );
    final key = Padding(
      padding: EdgeInsets.only(bottom: widget.travel),
      child: cap,
    );
    return widget.tooltip == null ? key : Tooltip(message: widget.tooltip, child: key);
  }
}

/// A small status light with a soft glow.
class Led extends StatelessWidget {
  const Led({super.key, required this.color, this.size = 8, this.glow = true});

  final Color color;
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: glow
          ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: size, spreadRadius: 0.5)]
          : null,
    ),
  );
}

/// A small label that looks pressed into the surface ("Peak speed", "Recent").
class EngravedLabel extends StatelessWidget {
  const EngravedLabel(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: t.engraved,
        shadows: [Shadow(color: t.engravedShadow, offset: Offset(0, dark ? -1 : 1))],
      ).merge(style),
    );
  }
}

/// The machined edge of a raised part: a lit line along the top and a shadowed line along
/// the bottom, drawn just inside the outline. This is what makes a soft neumorphic shape read
/// as a real, bevelled object.
class BevelPainter extends CustomPainter {
  const BevelPainter({
    required this.radius,
    required this.light,
    required this.dark,
    this.width = 1.2,
  });

  final double radius;
  final Color light;
  final Color dark;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [light, light.withValues(alpha: 0), dark.withValues(alpha: 0), dark],
          stops: const [0, 0.35, 0.7, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(BevelPainter old) =>
      old.radius != radius || old.light != light || old.dark != dark || old.width != width;
}

/// A specular shine across the upper part of a glossy key, as on moulded plastic.
class GlossPainter extends CustomPainter {
  const GlossPainter({required this.radius, required this.strength});

  final double radius;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas
      ..save()
      ..clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    final band = Rect.fromLTWH(0, 0, size.width, size.height * 0.5);
    canvas
      ..drawRRect(
        RRect.fromRectAndCorners(
          band.deflate(2),
          topLeft: Radius.circular(radius),
          topRight: Radius.circular(radius),
          bottomLeft: Radius.circular(radius * 0.6),
          bottomRight: Radius.circular(radius * 0.6),
        ),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: strength),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(band),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(GlossPainter old) => old.radius != radius || old.strength != strength;
}

/// The bevel colours for the current theme.
(Color, Color) bevelColors(BuildContext context) => TactileTokens.of(context).flat
    ? (Colors.transparent, Colors.transparent)
    : Theme.of(context).brightness == Brightness.dark
    ? (Colors.white.withValues(alpha: 0.06), Colors.black.withValues(alpha: 0.35))
    : (Colors.white, const Color(0xFF8E9DB5).withValues(alpha: 0.45));

/// A physical toggle: a sunken track and a glossy, bevelled knob that slides across it. When
/// on, the track lights up in the primary blue with a soft glow. Animates on change, on
/// hover (the knob swells a little) and while pressed (the knob squashes).
class TactileSwitch extends StatefulWidget {
  const TactileSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;

  @override
  State<TactileSwitch> createState() => _TactileSwitchState();
}

class _TactileSwitchState extends State<TactileSwitch> {
  bool _hovered = false;
  bool _down = false;
  bool _focused = false;

  static const _width = 58.0;
  static const _height = 32.0;
  static const _knob = 26.0;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onChanged != null;
    final on = widget.value;
    final (bevelLight, bevelDark) = bevelColors(context);
    final duration = still ? Duration.zero : const Duration(milliseconds: 220);
    const curve = Cubic(0.2, 0.8, 0.2, 1);
    final knobScale = !enabled || still ? 1.0 : (_down ? 0.9 : (_hovered ? 1.06 : 1.0));

    final track = AnimatedContainer(
      duration: duration,
      curve: curve,
      width: _width,
      height: _height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_height / 2),
        gradient: on
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [t.primaryDeep, t.primary],
              )
            : LinearGradient(colors: [t.recess, t.recess]),
        border: _focused ? Border.all(color: t.primary, width: 2) : null,
        boxShadow: on
            ? [BoxShadow(color: t.primary.withValues(alpha: 0.45), blurRadius: 10)]
            : null,
      ),
      child: CustomPaint(
        painter: InsetPainter(
          radius: _height / 2,
          fill: const LinearGradient(colors: [Colors.transparent, Colors.transparent]),
          shade: on ? Colors.black.withValues(alpha: 0.35) : t.innerShade,
          light: on ? Colors.white.withValues(alpha: 0.15) : t.innerLight,
          depth: 3,
        ),
        child: AnimatedAlign(
          duration: duration,
          curve: curve,
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: AnimatedScale(
              duration: still ? Duration.zero : const Duration(milliseconds: 120),
              scale: knobScale,
              child: Container(
                width: _knob,
                height: _knob,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [t.raisedTop, t.raisedBottom],
                  ),
                  boxShadow: [
                    BoxShadow(color: t.shade, blurRadius: 6, offset: const Offset(2, 3)),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 1,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: CustomPaint(
                  painter: const GlossPainter(radius: _knob / 2, strength: 0.6),
                  foregroundPainter: BevelPainter(
                    radius: _knob / 2,
                    light: bevelLight,
                    dark: bevelDark,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      toggled: on,
      enabled: enabled,
      label: widget.semanticLabel,
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: FocusableActionDetector(
          enabled: enabled,
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onShowHoverHighlight: (v) => setState(() => _hovered = v),
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => widget.onChanged?.call(!on),
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (_) => setState(() => _down = true) : null,
            onTapCancel: () => setState(() => _down = false),
            onTapUp: enabled ? (_) => setState(() => _down = false) : null,
            onTap: enabled ? () => widget.onChanged!(!on) : null,
            // A 48 px tall hit area around the 32 px track.
            child: SizedBox(
              width: _width,
              height: kMinTouchTarget,
              child: Center(child: track),
            ),
          ),
        ),
      ),
    );
  }
}

/// A setting row with a [TactileSwitch]: title, optional subtitle, the switch at the end.
/// Tapping anywhere on the row toggles it, as with a SwitchListTile.
class TactileSwitchTile extends StatelessWidget {
  const TactileSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.contentPadding,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: ListTile(
      contentPadding: contentPadding,
      title: title,
      subtitle: subtitle,
      enabled: onChanged != null,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: TactileSwitch(value: value, onChanged: onChanged),
    ),
  );
}

/// A small raised box that sits on a panel: a KPI, an address, a row. A shade deeper than
/// the panel so its shadow reads (as in the reference design), with a bevelled edge. With
/// [onTap] it is a button that lifts and outlines as a whole under the pointer.
class RaisedTile extends StatefulWidget {
  const RaisedTile({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Spacing.md + 2),
    this.radius = 14,
    this.onTap,
    this.semanticLabel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  State<RaisedTile> createState() => _RaisedTileState();
}

class _RaisedTileState extends State<RaisedTile> {
  bool _hovered = false;
  bool _down = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final (light, dark) = bevelColors(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final tappable = widget.onTap != null;
    final lifted = tappable && _hovered && !_down && !still;
    final shape = BorderRadius.circular(widget.radius);
    final top = Color.lerp(t.raisedBottom, t.recess, 0.15)!;
    final bottom = Color.lerp(t.raisedBottom, t.recess, 0.6)!;

    Widget body = Padding(padding: widget.padding, child: widget.child);
    if (tappable) {
      body = Semantics(
        button: true,
        label: widget.semanticLabel,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: shape,
          splashFactory: NoSplash.splashFactory,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          focusColor: Colors.transparent,
          onHover: (v) => setState(() => _hovered = v),
          onHighlightChanged: (v) => setState(() => _down = v),
          onFocusChange: (v) => setState(() => _focused = v),
          child: body,
        ),
      );
      body = Material(type: MaterialType.transparency, child: body);
    }

    return AnimatedContainer(
      duration: still ? Duration.zero : Duration(milliseconds: _down ? 60 : 180),
      curve: const Cubic(0.2, 0.8, 0.2, 1),
      transform: Matrix4.translationValues(0, lifted ? -3 : 0, 0)
        ..scaleByDouble(_down && !still ? 0.985 : 1, _down && !still ? 0.985 : 1, 1, 1),
      transformAlignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, bottom],
        ),
        borderRadius: shape,
        border: Border.all(
          color: _focused
              ? t.primary
              : (lifted ? t.primary.withValues(alpha: 0.4) : (t.flat ? t.rim : Colors.transparent)),
          width: _focused ? 2 : 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: t.shade,
            blurRadius: lifted ? 22 : 14,
            offset: Offset(lifted ? 6 : 4, lifted ? 10 : 6),
          ),
          BoxShadow(
            color: t.highlight.withValues(alpha: t.highlight.a * 0.7),
            blurRadius: 8,
            offset: const Offset(-3, -3),
          ),
        ],
      ),
      child: CustomPaint(
        foregroundPainter: BevelPainter(radius: widget.radius, light: light, dark: dark),
        child: body,
      ),
    );
  }
}

/// A headline number on a [RaisedTile]: a small uppercase label, the value, and an optional
/// note under it.
class KpiTile extends StatelessWidget {
  const KpiTile({super.key, required this.label, required this.value, this.note, this.valueColor});

  final String label;
  final String value;
  final String? note;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: RaisedTile(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.9,
                color: p.text3,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text(value, style: kFigureStyle.copyWith(fontSize: 26, color: valueColor ?? p.ink)),
            if (note != null) ...[
              const SizedBox(height: Spacing.xs),
              Text(note!, style: text.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// A shallow sunken tray that holds a list or table inside a panel.
class Tray extends StatelessWidget {
  const Tray({super.key, required this.child, this.padding = const EdgeInsets.all(Spacing.xs)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    return Recess(
      radius: 14,
      depth: 3,
      color: Color.lerp(t.recess, t.raisedBottom, 0.35),
      padding: padding,
      child: child,
    );
  }
}

/// A single hairline of light along the top edge of a key, fading out down the sides.
class _TopLightPainter extends CustomPainter {
  const _TopLightPainter({required this.radius});

  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(0.5);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.4),
            Colors.white.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.22),
          ],
          stops: const [0, 0.4, 0.7, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_TopLightPainter old) => old.radius != radius;
}

/// A recessed tray that holds a row of segments (a segmented control): the options sit in
/// the tray and the chosen one is a raised face inside it.
class SegmentTray extends StatelessWidget {
  const SegmentTray({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      InsetBox(radius: 14, padding: const EdgeInsets.all(4), child: child);
}
