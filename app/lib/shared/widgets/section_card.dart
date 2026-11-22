import 'package:flutter/material.dart';

import 'surfaces.dart';

/// Titled card used for result panels (minimap, scoreboard, timeline, …).
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => AppCard(title: title, actions: [?trailing], child: child);
}
