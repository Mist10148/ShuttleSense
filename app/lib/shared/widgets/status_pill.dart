import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// What a [StatusPill] reports. Each tone has a pastel fill; the dot carries the strong colour
/// and the text stays ink at full contrast.
enum PillTone { neutral, good, info, warning, bad }

/// A small rounded label: "Online", "Done", "Coach chat: off". Without the [dot] it is a plain
/// pastel badge ("Upload", "Beta").
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, this.tone = PillTone.neutral, this.dot = true});

  final String label;
  final PillTone tone;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = AppPalette.of(context);
    final status = StatusColors.of(context);
    final (fill, mark) = switch (tone) {
      PillTone.good => (p.mint, status.inCall),
      PillTone.info => (p.sky, p.info),
      PillTone.warning => (p.peach, status.uncertain),
      PillTone.bad => (p.pink, status.outCall),
      PillTone.neutral => (p.surface2, p.text3),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + 2, vertical: Spacing.xs),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: Spacing.sm,
              height: Spacing.sm,
              decoration: BoxDecoration(color: mark, shape: BoxShape.circle),
            ),
            const SizedBox(width: Spacing.xs + 2),
          ],
          Flexible(
            child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: p.ink)),
          ),
        ],
      ),
    );
  }
}
