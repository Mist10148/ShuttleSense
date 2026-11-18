import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// What a [StatusPill] reports. The dot carries the colour; the text stays at full contrast.
enum PillTone { neutral, good, warning, bad }

/// A small rounded label with a coloured dot: "Online", "Done", "Coach chat: off".
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, this.tone = PillTone.neutral});

  final String label;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = StatusColors.of(context);
    final dot = switch (tone) {
      PillTone.good => status.inCall,
      PillTone.warning => status.uncertain,
      PillTone.bad => status.outCall,
      PillTone.neutral => theme.colorScheme.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.xs),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: Spacing.sm,
            height: Spacing.sm,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: Spacing.xs + 2),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
