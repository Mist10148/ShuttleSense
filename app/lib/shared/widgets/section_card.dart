import 'package:flutter/material.dart';

import 'surfaces.dart';

/// Titled card used for result panels (minimap, scoreboard, timeline, …).
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.icon,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  /// A small icon in a sunken well before the title.
  final IconData? icon;

  @override
  Widget build(BuildContext context) =>
      AppCard(title: title, icon: icon, actions: [?trailing], child: child);
}
