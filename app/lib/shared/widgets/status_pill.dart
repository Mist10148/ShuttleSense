import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import 'tactile.dart';

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
    final dark = theme.brightness == Brightness.dark;
    // A tinted badge: the bar colour lights the dot and tints the fill and edge; the text
    // takes a deeper shade of it that keeps 4.5:1 on the tint.
    final (bar, ink) = switch (tone) {
      PillTone.good => (const Color(0xFF2E9E6B), p.brand),
      PillTone.info => (const Color(0xFF3F72AF), p.info),
      PillTone.warning => (
        const Color(0xFFE0911E),
        dark ? const Color(0xFFE6A54A) : const Color(0xFF8A5205),
      ),
      PillTone.bad => (
        const Color(0xFFD64545),
        dark ? const Color(0xFFF07B7B) : const Color(0xFFA82C2C),
      ),
      PillTone.neutral => (const Color(0xFF8592A3), p.text2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + 1, vertical: 3),
      decoration: BoxDecoration(
        color: bar.withValues(alpha: dark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: bar.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Led(color: bar, size: 6, glow: tone != PillTone.neutral),
            const SizedBox(width: Spacing.xs + 2),
          ],
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: ink, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
