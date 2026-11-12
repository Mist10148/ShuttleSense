import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// Titled card used for result panels (minimap, scoreboard, timeline, …).
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
                ?trailing,
              ],
            ),
            const SizedBox(height: Spacing.md),
            child,
          ],
        ),
      ),
    );
  }
}
