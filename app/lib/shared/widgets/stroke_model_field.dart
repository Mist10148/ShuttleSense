import 'package:flutter/material.dart';

import '../../data/models/health.dart';
import '../../data/models/job.dart';
import '../../core/theme/tokens.dart';

/// The stroke classifier choice: CNN, LSTM or Random Forest (Phase 11).
///
/// A model the server has not installed is greyed out. On a server that does not offer the
/// choice (older than clip record 1.4) the field is hidden.
class StrokeModelField extends StatelessWidget {
  const StrokeModelField({
    super.key,
    required this.value,
    required this.health,
    required this.onChanged,
  });

  /// The remembered choice; the highlighted one is what this server will actually run.
  final String? value;
  final Health? health;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final installed = health?.strokeModels;
    if (health != null && installed == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    bool available(String model) => installed == null || installed.contains(model);
    final shown = resolveStrokeModel(value, health) ?? value ?? kStrokeModels.keys.first;
    final missing = [
      for (final MapEntry(key: model, value: label) in kStrokeModels.entries)
        if (!available(model)) label,
    ];
    final String help;
    if (missing.isEmpty) {
      help = 'Which classifier names each stroke. All three read the same pose and shuttle data.';
    } else if (missing.length == kStrokeModels.length) {
      help = 'No stroke model is installed on this server, so strokes stay unnamed.';
    } else {
      help = 'Not installed on this server: ${missing.join(', ')}.';
    }
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text('Stroke model', style: theme.textTheme.labelLarge),
              SegmentedButton<String>(
                segments: [
                  for (final MapEntry(key: model, value: label) in kStrokeModels.entries)
                    ButtonSegment(value: model, label: Text(label), enabled: available(model)),
                ],
                selected: {shown},
                onSelectionChanged: (s) => onChanged(s.first),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text(help, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
