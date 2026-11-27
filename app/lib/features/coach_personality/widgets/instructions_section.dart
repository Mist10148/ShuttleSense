import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../personality_models.dart';
import '../personality_text.dart';

/// The player's own words about how the coach should talk, plus words to prefer or avoid
/// and expressions it may use (communication-preferences.md, Custom instructions). Style
/// only: the server keeps this text in a block that cannot change the rules.
class InstructionsSection extends StatefulWidget {
  const InstructionsSection({
    super.key,
    required this.instructions,
    required this.vocabulary,
    required this.onInstructions,
    required this.onVocabulary,
    this.enabled = true,
  });

  final String instructions;
  final CoachVocabulary vocabulary;
  final ValueChanged<String> onInstructions;
  final ValueChanged<CoachVocabulary> onVocabulary;
  final bool enabled;

  @override
  State<InstructionsSection> createState() => _InstructionsSectionState();
}

class _InstructionsSectionState extends State<InstructionsSection> {
  late final _text = TextEditingController(text: widget.instructions);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme;
    final v = widget.vocabulary;
    final warn = looksLikeRuleChange(_text.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('instructions-text'),
          controller: _text,
          enabled: widget.enabled,
          minLines: 3,
          maxLines: 8,
          maxLength: kMaxInstructions,
          decoration: InputDecoration(
            labelText: 'Tell the coach how to talk (optional)',
            hintText: 'Be strict about footwork. Call my backhand "the problem child".',
            alignLabelWithHint: true,
            helperText: warn
                ? null
                : "Style only. The coach's rules, data and safety don't change.",
            helperMaxLines: 2,
            errorText: warn
                ? "Parts of this look like instructions to change the coach's rules. "
                      'They will be ignored.'
                : null,
            errorMaxLines: 3,
          ),
          onChanged: (t) {
            setState(() {});
            widget.onInstructions(t);
          },
        ),
        const SizedBox(height: Spacing.md),
        _Words(
          id: 'preferred',
          label: 'Preferred words',
          hint: 'kill, or clear = lob to the back',
          words: v.preferred,
          max: kMaxWords,
          maxLength: kMaxWord,
          enabled: widget.enabled,
          onChanged: (w) => widget.onVocabulary(v.copyWith(preferred: w)),
        ),
        _Words(
          id: 'avoid',
          label: 'Words to avoid',
          hint: 'lob',
          words: v.avoid,
          max: kMaxWords,
          maxLength: kMaxWord,
          enabled: widget.enabled,
          onChanged: (w) => widget.onVocabulary(v.copyWith(avoid: w)),
        ),
        _Words(
          id: 'phrases',
          label: 'Expressions it may use now and then',
          hint: 'Feet first!',
          words: v.catchphrases,
          max: kMaxPhrases,
          maxLength: kMaxPhrase,
          enabled: widget.enabled,
          onChanged: (w) => widget.onVocabulary(v.copyWith(catchphrases: w)),
        ),
        Text('Up to $kMaxWords words and $kMaxPhrases expressions.', style: style.bodySmall),
      ],
    );
  }
}

/// A list of short entries shown as chips, with a field to add one.
class _Words extends StatefulWidget {
  const _Words({
    required this.id,
    required this.label,
    required this.hint,
    required this.words,
    required this.max,
    required this.maxLength,
    required this.onChanged,
    required this.enabled,
  });

  final String id;
  final String label;
  final String hint;
  final List<String> words;
  final int max;
  final int maxLength;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;

  @override
  State<_Words> createState() => _WordsState();
}

class _WordsState extends State<_Words> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _add() {
    final w = _field.text.trim();
    if (w.isEmpty || widget.words.length >= widget.max || widget.words.contains(w)) return;
    widget.onChanged([...widget.words, w]);
    _field.clear();
  }

  @override
  Widget build(BuildContext context) {
    final full = widget.words.length >= widget.max;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey('words-${widget.id}'),
                  controller: _field,
                  enabled: widget.enabled && !full,
                  maxLength: widget.maxLength,
                  decoration: InputDecoration(
                    labelText: widget.label,
                    hintText: widget.hint,
                    counterText: '',
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              IconButton(
                key: ValueKey('words-${widget.id}-add'),
                tooltip: 'Add to ${widget.label.toLowerCase()}',
                onPressed: widget.enabled && !full ? _add : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (widget.words.isNotEmpty) ...[
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.xs,
              children: [
                for (final w in widget.words)
                  InputChip(
                    label: Text(w),
                    deleteButtonTooltipMessage: 'Remove $w',
                    onDeleted: widget.enabled
                        ? () => widget.onChanged([...widget.words]..remove(w))
                        : null,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
