import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// "1 Video → 2 Options → 3 Upload": a bar per step, filled up to [current] (0-based).
class StepIndicator extends StatelessWidget {
  const StepIndicator({super.key, required this.steps, required this.current});

  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = AppPalette.of(context);
    return Semantics(
      label: 'Step ${current + 1} of ${steps.length}: ${steps[current]}',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, step) in steps.indexed) ...[
            if (i > 0) const SizedBox(width: Spacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: Spacing.sm - 2,
                    decoration: BoxDecoration(
                      color: i <= current ? null : p.surface2,
                      gradient: i <= current ? LinearGradient(colors: p.progress) : null,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '${i + 1} $step',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: i == current ? p.ink : p.text2,
                      fontWeight: i == current ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
