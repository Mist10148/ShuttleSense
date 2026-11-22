import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// Centered icon + message (+ optional action) for empty, error and placeholder states.
class MessageView extends StatelessWidget {
  const MessageView({
    super.key,
    required this.icon,
    required this.message,
    this.detail,
    this.action,
  });

  final IconData icon;
  final String message;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = AppPalette.of(context);
    // Scrolls rather than overflowing in a small box (the video slot on a phone) or at
    // large text sizes.
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The icon sits in a pastel disc so empty and error states look deliberate.
            Container(
              padding: const EdgeInsets.all(Spacing.xl),
              decoration: BoxDecoration(color: p.lavender, shape: BoxShape.circle),
              child: Icon(icon, size: 40, color: p.ink),
            ),
            const SizedBox(height: Spacing.lg),
            Text(message, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            if (detail != null) ...[
              const SizedBox(height: Spacing.xs),
              Text(
                detail!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: Spacing.lg), action!],
          ],
        ),
      ),
    );
  }
}
