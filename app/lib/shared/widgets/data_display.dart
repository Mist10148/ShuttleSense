import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'tactile.dart';

/// A big light number with its unit and a caption: "312 km/h · Max smash".
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.unit, this.icon});

  final String label;
  final String value;
  final String? unit;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: '$label: $value${unit == null ? '' : ' $unit'}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 16, color: p.text2),
                const SizedBox(width: Spacing.xs),
              ],
              Flexible(child: Text(label, style: text.bodySmall)),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: value, style: text.displaySmall),
                if (unit != null)
                  TextSpan(
                    text: ' $unit',
                    style: text.bodyMedium?.copyWith(color: p.text2),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One row of a list or leaderboard: a leading chip, a title and a muted line, and on the
/// right either a big [value] or any [trailing] widget.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
  });

  final Widget? leading;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
      minVerticalPadding: Spacing.sm,
      leading: leading,
      title: Text(title, style: text.titleSmall),
      subtitle: subtitle == null ? null : Text(subtitle!, style: text.bodySmall),
      trailing: trailing ?? (value == null ? null : Text(value!, style: text.headlineMedium)),
      onTap: onTap,
    );
  }
}

/// A rounded progress bar filled with the blue-to-mint gradient. [value] runs 0 to 1.
class GradientProgress extends StatelessWidget {
  const GradientProgress({super.key, required this.value, this.label, this.height = 8});

  final double value;

  /// What the bar measures, for screen readers ("Processing").
  final String? label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final fraction = value.clamp(0.0, 1.0);
    final shape = BorderRadius.circular(Radii.pill);
    return Semantics(
      label: label,
      value: '${(fraction * 100).round()}%',
      child: Recess(
        radius: Radii.pill,
        padding: EdgeInsets.zero,
        depth: 2,
        child: SizedBox(
          height: height,
          child: Align(
            alignment: Alignment.centerLeft,
            child: AnimatedFractionallySizedBox(
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : Motion.normal,
              curve: Motion.curve,
              widthFactor: fraction,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: shape,
                  gradient: LinearGradient(colors: p.progress),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A grey placeholder block that gently pulses while data loads (still under reduced motion,
/// or with [pulse] off for a preview that stays on screen for minutes).
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height = 16,
    this.radius = Radii.sm,
    this.pulse = true,
  });

  final double? width;
  final double height;
  final double radius;
  final bool pulse;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
    lowerBound: 0.5,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.pulse || MediaQuery.disableAnimationsOf(context)) {
      _pulse
        ..stop()
        ..value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return ExcludeSemantics(
      child: FadeTransition(
        opacity: _pulse,
        child: Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: p.surface2,
            borderRadius: BorderRadius.circular(widget.radius),
          ),
        ),
      ),
    );
  }
}
