import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../data/api_client.dart';
import '../../../data/models/json.dart';
import '../../../data/repositories/analysis_repository.dart';
import '../keyword_mapper.dart';
import '../personality_models.dart';
import '../personality_notifier.dart';
import '../personality_text.dart';
import '../presets.dart';

/// Describe the coach in your own words and get a draft to review
/// (docs/coach-personality/generator.md). Nothing is saved until the player saves it.
class GeneratorSection extends ConsumerStatefulWidget {
  const GeneratorSection({super.key, required this.onDraft, this.enabled = true});

  /// Called with the reviewed draft; the page loads it for editing and saving.
  final ValueChanged<PersonalityProfile> onDraft;
  final bool enabled;

  @override
  ConsumerState<GeneratorSection> createState() => _GeneratorSectionState();
}

class _GeneratorSectionState extends ConsumerState<GeneratorSection> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;
  int _run = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final description = _text.text.trim();
    if (description.isEmpty) return;
    final run = ++_run;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final json = await ref.read(apiClientProvider).generatePersonality(description);
      if (!mounted || run != _run) return;
      setState(() => _busy = false);
      await _review(profileFromDraft(json, ref.read(personalityProvider.notifier)), json);
    } on ApiException catch (e) {
      _fail(run, e.message);
    } on Object catch (e) {
      _fail(run, '$e');
    }
  }

  void _fail(int run, String message) {
    if (!mounted || run != _run) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  void _cancel() => setState(() {
    _run++;
    _busy = false;
  });

  Future<void> _offline() async {
    final draft = draftFromKeywords(_text.text);
    final notifier = ref.read(personalityProvider.notifier);
    final base = presetById(draft.basePreset).attributes;
    final profile = notifier
        .draftFrom(basePreset: draft.basePreset, name: 'My coach')
        .copyWith(
          overrides: {
            for (final e in draft.values.entries)
              if (base[e.key.index] != e.value) e.key: e.value,
          },
          instructions: _text.text.trim().length > kMaxInstructions
              ? _text.text.trim().substring(0, kMaxInstructions)
              : _text.text.trim(),
          source: ProfileSource.generated,
        );
    setState(() => _error = null);
    await _review(profile, null, offline: true, matched: draft.matched);
  }

  Future<void> _review(
    PersonalityProfile profile,
    Json? json, {
    bool offline = false,
    List<String> matched = const [],
  }) async {
    final notes = [
      if (json?['notes'] is List)
        for (final n in json!['notes'] as List) '$n',
      if (offline)
        matched.isEmpty
            ? 'No style words were recognised; it starts from Default.'
            : 'Read from: ${matched.join(', ')}.',
    ];
    final use = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ReviewSheet(profile: profile, notes: notes, offline: offline),
    );
    if (use == true) widget.onDraft(profile);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final ready = widget.enabled && !_busy && _text.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('generator-text'),
          controller: _text,
          enabled: widget.enabled,
          readOnly: _busy,
          minLines: 2,
          maxLines: 5,
          maxLength: kMaxDescription,
          decoration: const InputDecoration(
            labelText: 'Describe your coach',
            hintText: 'A calm older coach who is strict about footwork and a little dry',
            alignLabelWithHint: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const ValueKey('generator-go'),
              onPressed: ready ? _generate : null,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              label: Text(_busy ? 'Drafting…' : 'Draft with AI'),
            ),
            if (_busy)
              TextButton(
                key: const ValueKey('generator-cancel'),
                onPressed: _cancel,
                child: const Text('Cancel'),
              )
            else
              TextButton(
                key: const ValueKey('generator-offline'),
                onPressed: widget.enabled && _text.text.trim().isNotEmpty ? _offline : null,
                child: const Text('Draft without AI'),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: Spacing.sm),
          Semantics(
            liveRegion: true,
            child: Text(
              "Couldn't draft one: $_error. Try again, or draft without AI.",
              key: const ValueKey('generator-error'),
              style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        const SizedBox(height: Spacing.xs),
        Text(
          'Only your description is sent, to the coach\'s AI provider. You review the draft '
          'before anything is saved.',
          style: text.bodySmall,
        ),
      ],
    );
  }
}

/// A server draft (POST /coach/personality/generate) as an unsaved profile.
PersonalityProfile profileFromDraft(Json json, PersonalityNotifier notifier) {
  final preset = presetById('${json['basePreset']}');
  final attrs = json['attributes'] is Map ? json['attributes'] as Map : const {};
  final overrides = <PersonalityAttr, int>{
    for (final a in PersonalityAttr.values)
      if (attrs[a.name] is num && (attrs[a.name] as num).round() != preset.attributes[a.index])
        a: (attrs[a.name] as num).round().clamp(0, 100),
  };
  final name = '${json['name'] ?? ''}'.trim();
  return notifier
      .draftFrom(basePreset: preset.id, name: name.isEmpty ? 'My coach' : name)
      .copyWith(
        overrides: overrides,
        preferences: CommunicationPrefs.fromJson(json['preferences']),
        instructions: '${json['instructions'] ?? ''}',
        description: '${json['description'] ?? ''}',
        source: ProfileSource.generated,
      );
}

class _ReviewSheet extends StatelessWidget {
  const _ReviewSheet({required this.profile, required this.notes, required this.offline});

  final PersonalityProfile profile;
  final List<String> notes;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final preset = presetById(profile.basePreset);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
          children: [
            Semantics(header: true, child: Text(profile.name, style: text.titleLarge)),
            const SizedBox(height: Spacing.xs),
            Text(
              offline
                  ? 'Made without AI: check the sliders.'
                  : 'Generated draft. Review it before saving.',
              style: text.labelLarge,
            ),
            if (profile.description.isNotEmpty) ...[
              const SizedBox(height: Spacing.sm),
              Text(profile.description, style: text.bodyMedium),
            ],
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Icon(preset.icon),
                const SizedBox(width: Spacing.sm),
                Text('Based on ${preset.label}', style: text.titleSmall),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            for (final a in PersonalityAttr.values)
              Text(
                '${a.label}: ${profile.overrides[a] ?? preset.attributes[a.index]} '
                '(${AttrBand.of(profile.overrides[a] ?? preset.attributes[a.index]).label})'
                '${profile.overrides.containsKey(a) ? ' · changed' : ''}',
                style: text.bodySmall,
              ),
            if (profile.instructions.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              Text('Instructions', style: text.titleSmall),
              Text(profile.instructions, style: text.bodyMedium),
            ],
            if (notes.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              Text('Notes', style: text.titleSmall),
              for (final n in notes) Text('• $n', style: text.bodySmall),
            ],
            const SizedBox(height: Spacing.lg),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('review-discard'),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Discard'),
                ),
                FilledButton(
                  key: const ValueKey('review-use'),
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Edit and save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
