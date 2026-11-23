import 'package:flutter/material.dart';

import '../../data/models/health.dart';
import '../../data/models/job.dart';
import '../../core/theme/tokens.dart';
import 'tactile.dart';

/// One line on what each model is (D28, D37). The CNN is the default, so it is the one marked
/// recommended.
const _kModelNotes = <String, String>{
  'cnn': 'Recommended. The default: a 1D convolutional network over the pose and shuttle window.',
  'lstm': 'A recurrent network that reads the same window as a sequence.',
  'rf': 'A classical Random Forest on summary values of the window.',
  'ensemble': 'Averages the CNN, LSTM and Random Forest. Runs all three, so it is slower.',
};

/// The stroke classifier choice: CNN, LSTM, Random Forest, or the three together (Phase 11).
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
    // The ensemble has no weights of its own: it is missing whenever one of the three is,
    // so only those are named.
    final trained = {
      for (final e in kStrokeModels.entries)
        if (e.key != 'ensemble') e.key: e.value,
    };
    final missing = [
      for (final MapEntry(key: model, value: label) in trained.entries)
        if (!available(model)) label,
    ];
    final String help;
    if (missing.isEmpty) {
      help =
          'Which classifier names each stroke. All read the same pose and shuttle data; '
          'Ensemble averages the other three.';
    } else if (missing.length == trained.length) {
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
              SegmentTray(
                child: SegmentedButton<String>(
                  segments: [
                    for (final MapEntry(key: model, value: label) in kStrokeModels.entries)
                      ButtonSegment(value: model, label: Text(label), enabled: available(model)),
                  ],
                  selected: {shown},
                  onSelectionChanged: (s) => onChanged(s.first),
                ),
              ),
            ],
          ),
          if (_kModelNotes[shown] case final note? when available(shown))
            Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: Text('${kStrokeModels[shown]}: $note', style: theme.textTheme.bodyMedium),
            ),
          Padding(
            padding: const EdgeInsets.only(top: Spacing.xs),
            child: Text(
              help,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
