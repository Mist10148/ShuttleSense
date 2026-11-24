import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'surfaces.dart';

/// Titled card used for result panels (minimap, scoreboard, timeline, …).
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.icon,
    this.padding,
  });

  /// Inner padding; the card's standard padding when null.
  final EdgeInsetsGeometry? padding;

  final String title;
  final Widget child;
  final Widget? trailing;

  /// A small icon in a sunken well before the title.
  final IconData? icon;

  @override
  Widget build(BuildContext context) => padding == null
      ? AppCard(title: title, icon: icon, actions: [?trailing], child: child)
      : AppCard(title: title, icon: icon, actions: [?trailing], padding: padding!, child: child);
}

/// A titled block with no card of its own, for content that already sits inside a panel
/// (the Results tabs): a card there would be a box in a box.
class SectionBlock extends StatelessWidget {
  const SectionBlock({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Semantics(
        header: true,
        child: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
        ),
      ),
      const SizedBox(height: Spacing.lg),
      child,
    ],
  );
}
