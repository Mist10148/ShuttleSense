import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/tactile.dart';
import '../personality_models.dart';

/// How the coach talks apart from its personality: length, level, emoji, humour, pushback,
/// initiative and emotion (docs/coach-personality/communication-preferences.md).
class PreferencesSection extends StatelessWidget {
  const PreferencesSection({
    super.key,
    required this.prefs,
    required this.onChanged,
    this.enabled = true,
  });

  final CommunicationPrefs prefs;
  final ValueChanged<CommunicationPrefs> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'These win over the sliders. What you ask for in a message wins over these.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      _Choice<ResponseLength>(
        id: 'length',
        label: 'Response length',
        values: ResponseLength.values,
        value: prefs.responseLength,
        enabled: enabled,
        onChanged: (v) => onChanged(prefs.copyWith(responseLength: v)),
      ),
      _Choice<ExplanationLevel>(
        id: 'level',
        label: 'Explanation level',
        values: ExplanationLevel.values,
        value: prefs.explanationLevel,
        enabled: enabled,
        onChanged: (v) => onChanged(prefs.copyWith(explanationLevel: v)),
      ),
      _Choice<EmojiUsage>(
        id: 'emoji',
        label: 'Emoji',
        values: EmojiUsage.values,
        value: prefs.emoji,
        enabled: enabled,
        onChanged: (v) => onChanged(prefs.copyWith(emoji: v)),
      ),
      _Choice<HumorStyle>(
        id: 'humor',
        label: 'Humor style',
        values: HumorStyle.values,
        value: prefs.humorStyle,
        enabled: enabled,
        onChanged: (v) => onChanged(prefs.copyWith(humorStyle: v)),
      ),
      _Choice<CriticalThinking>(
        id: 'pushback',
        label: 'Pushback',
        values: CriticalThinking.values,
        value: prefs.criticalThinking,
        enabled: enabled,
        onChanged: (v) => onChanged(prefs.copyWith(criticalThinking: v)),
      ),
      _Choice<Initiative>(
        id: 'initiative',
        label: 'Initiative',
        values: Initiative.values,
        value: prefs.initiative,
        enabled: enabled,
        onChanged: (v) => onChanged(prefs.copyWith(initiative: v)),
      ),
      _Choice<EmotionalExpression>(
        id: 'emotion',
        label: 'Emotion',
        values: EmotionalExpression.values,
        value: prefs.emotionalExpression,
        enabled: enabled,
        onChanged: (v) => onChanged(prefs.copyWith(emotionalExpression: v)),
      ),
      const SizedBox(height: Spacing.sm),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('prefs-reset'),
          onPressed: enabled && !prefs.isDefault
              ? () => onChanged(CommunicationPrefs(addressByName: prefs.addressByName))
              : null,
          icon: const Icon(Icons.restart_alt),
          label: const Text('Reset these options'),
        ),
      ),
    ],
  );
}

/// One option: segments when it has up to four values, a menu otherwise.
class _Choice<T extends Enum> extends StatelessWidget {
  const _Choice({
    required this.id,
    required this.label,
    required this.values,
    required this.value,
    required this.onChanged,
    required this.enabled,
  });

  final String id;
  final String label;
  final List<T> values;
  final T value;
  final ValueChanged<T> onChanged;
  final bool enabled;

  String _label(T v) => (v as LabelledChoice).label;
  String _help(T v) => (v as LabelledChoice).help;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.titleSmall),
          const SizedBox(height: Spacing.xs),
          if (values.length <= 4)
            DepthSegmented<T>(
              key: ValueKey('pref-$id'),
              compact: true,
              wrapLabels: true,
              segments: [
                for (final v in values)
                  ButtonSegment(value: v, label: Text(_label(v)), tooltip: _help(v)),
              ],
              selected: {value},
              onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
            )
          else
            DropdownMenu<T>(
              key: ValueKey('pref-$id'),
              enabled: enabled,
              initialSelection: value,
              expandedInsets: EdgeInsets.zero,
              dropdownMenuEntries: [
                for (final v in values) DropdownMenuEntry(value: v, label: _label(v)),
              ],
              onSelected: (v) => v == null ? null : onChanged(v),
            ),
          const SizedBox(height: Spacing.xs),
          Text(_help(value), style: text.bodySmall),
        ],
      ),
    );
  }
}
