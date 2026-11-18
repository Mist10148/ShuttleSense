import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';

/// A one-line explanation under a control: why a button is disabled, what an option costs,
/// or what turning something off takes away. [warning] adds an amber icon; [error] uses the
/// theme's error colour for the text as well.
class HelperText extends StatelessWidget {
  const HelperText(this.text, {super.key, this.warning = false, this.error = false});

  final String text;
  final bool warning;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, iconColor) = error
        ? (Icons.error_outline, scheme.error)
        : warning
        ? (Icons.warning_amber_rounded, StatusColors.of(context).uncertain)
        : (Icons.info_outline, scheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: Spacing.xs + 2),
          Expanded(
            child: Text(
              text,
              // onSurfaceVariant keeps at least 4.5:1 on every surface in both themes.
              style: theme.textTheme.bodySmall?.copyWith(
                color: error ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
