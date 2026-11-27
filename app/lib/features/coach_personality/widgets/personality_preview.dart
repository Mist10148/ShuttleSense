import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/tactile.dart';
import '../../../ui/depth.dart';
import '../../coach/coach_screen.dart';
import '../presets.dart';

/// A sample question and the preset's hand-written reply, so the player hears a voice before
/// choosing it (docs/coach-personality/presets.md, Preview scenarios). No network call.
class PersonalityPreview extends StatefulWidget {
  const PersonalityPreview({super.key, required this.preset, this.edited = false});

  final PersonalityPreset preset;

  /// The player changed this personality; the samples show the preset as it comes.
  final bool edited;

  @override
  State<PersonalityPreview> createState() => _PersonalityPreviewState();
}

class _PersonalityPreviewState extends State<PersonalityPreview> {
  int _scenario = 0;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final previews = widget.preset.previews;
    return InsetBox(
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text('Preview', style: text.labelLarge),
              DepthSegmented<int>(
                key: const ValueKey('preview-scenario'),
                compact: true,
                segments: const [
                  ButtonSegment(value: 0, label: Text('Technique')),
                  ButtonSegment(value: 1, label: Text('Setback')),
                ],
                selected: {_scenario},
                onSelectionChanged: (s) => setState(() => _scenario = s.first),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          if (previews.isEmpty)
            Text(
              'Custom has no sample replies: it sounds the way you set it. Try it in the coach.',
              style: muted,
            )
          else ...[
            CoachBubble(
              turn: CoachTurn(
                message: ChatMessage(role: 'user', text: kPreviewQuestions[_scenario]),
              ),
            ),
            CoachBubble(
              turn: CoachTurn(
                message: ChatMessage(role: 'assistant', text: previews[_scenario]),
              ),
            ),
          ],
          if (widget.edited) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              'Sample of ${widget.preset.label} as it comes; your changes apply in chat.',
              style: muted,
            ),
          ],
          const SizedBox(height: Spacing.xs),
          Text('When you mention pain or something hard, every coach gets serious.', style: muted),
        ],
      ),
    );
  }
}
