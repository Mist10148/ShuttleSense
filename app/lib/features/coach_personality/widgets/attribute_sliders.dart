import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/tokens.dart';
import '../personality_models.dart';
import '../presets.dart';

/// The ten attribute sliders of a personality, each with its band, the preset's own value
/// and a reset (docs/coach-personality/ui-ux.md, Personality section).
class AttributeSliders extends StatelessWidget {
  const AttributeSliders({
    super.key,
    required this.preset,
    required this.overrides,
    required this.onChanged,
    this.enabled = true,
  });

  final PersonalityPreset preset;
  final Map<PersonalityAttr, int> overrides;
  final ValueChanged<Map<PersonalityAttr, int>> onChanged;
  final bool enabled;

  int _value(PersonalityAttr a) => overrides[a] ?? preset.attributes[a.index];

  /// Combinations the coach softens, shown under the slider that causes them
  /// (attributes.md, Interactions and guards).
  String? _hint(PersonalityAttr a) {
    int v(PersonalityAttr x) => _value(x);
    return switch (a) {
      PersonalityAttr.sarcasm when v(a) >= 61 && v(PersonalityAttr.warmth) <= 20 =>
        'Sarcasm stays aimed at shots and situations, never at you.',
      PersonalityAttr.assertiveness when v(a) >= 81 && v(PersonalityAttr.empathy) <= 20 =>
        'Firm, never harsh: no shaming or guilt.',
      PersonalityAttr.humor when v(a) >= 61 && v(PersonalityAttr.verbosity) <= 20 =>
        'Short answers keep humour to one aside.',
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final changed = [
      for (final a in PersonalityAttr.values)
        if (_value(a) != preset.attributes[a.index]) a,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Tendencies, not exact amounts. Your words and the options below win over these.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: Spacing.sm),
        for (final a in PersonalityAttr.values)
          _AttributeSlider(
            key: ValueKey('attr-${a.name}'),
            attr: a,
            value: _value(a),
            presetValue: preset.attributes[a.index],
            presetLabel: preset.label,
            hint: _hint(a),
            enabled: enabled,
            onChanged: (v) {
              final next = {...overrides};
              if (v == preset.attributes[a.index]) {
                next.remove(a);
              } else {
                next[a] = v;
              }
              onChanged(next);
            },
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('attr-reset-all'),
            onPressed: enabled && changed.isNotEmpty ? () => onChanged(const {}) : null,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset all sliders'),
          ),
        ),
      ],
    );
  }
}

class _AttributeSlider extends StatelessWidget {
  const _AttributeSlider({
    super.key,
    required this.attr,
    required this.value,
    required this.presetValue,
    required this.presetLabel,
    required this.onChanged,
    required this.enabled,
    this.hint,
  });

  final PersonalityAttr attr;
  final int value;
  final int presetValue;
  final String presetLabel;
  final ValueChanged<int> onChanged;
  final bool enabled;
  final String? hint;

  void _step(int by) => onChanged((value + by).clamp(0, 100));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final band = AttrBand.of(value).label;
    final changed = value != presetValue;
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Tooltip(
                  message: '${attr.low} → ${attr.high}',
                  child: Text(attr.label, style: text.titleSmall),
                ),
              ),
              Text('$value · $band', style: text.labelLarge),
              SizedBox(
                width: kMinInteractiveDimension,
                child: changed
                    ? IconButton(
                        key: ValueKey('attr-reset-${attr.name}'),
                        tooltip: 'Reset ${attr.label} to $presetValue',
                        onPressed: enabled ? () => onChanged(presetValue) : null,
                        icon: const Icon(Icons.undo, size: 20),
                      )
                    : null,
              ),
            ],
          ),
          // Page Up/Down move by 20 and Home/End go to the ends (WAI-ARIA slider pattern);
          // the arrow keys step by 5 through the slider's divisions.
          Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.pageUp): _StepIntent(20),
              SingleActivator(LogicalKeyboardKey.pageDown): _StepIntent(-20),
              SingleActivator(LogicalKeyboardKey.home): _StepIntent(-100),
              SingleActivator(LogicalKeyboardKey.end): _StepIntent(100),
            },
            child: Actions(
              actions: {_StepIntent: CallbackAction<_StepIntent>(onInvoke: (i) => _step(i.by))},
              child: Semantics(
                hint: '$presetLabel default is $presetValue',
                child: Slider(
                  value: value.toDouble(),
                  max: 100,
                  divisions: 20,
                  label: '$value · $band',
                  semanticFormatterCallback: (v) => '${v.round()}, ${AttrBand.of(v.round()).label}',
                  onChanged: enabled ? (v) => onChanged(v.round()) : null,
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(child: Text(attr.low, style: muted)),
              Text('$presetLabel: $presetValue', style: muted),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(attr.high, style: muted, textAlign: TextAlign.end),
              ),
            ],
          ),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Text(hint!, key: ValueKey('attr-hint-${attr.name}'), style: muted),
            ),
        ],
      ),
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.by);

  final int by;
}
