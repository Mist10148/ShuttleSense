import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/page_scaffold.dart';
import 'personality_models.dart';
import 'personality_notifier.dart';
import 'personality_switcher_sheet.dart';
import 'presets.dart';
import 'widgets/attribute_sliders.dart';
import 'widgets/collapsible_section.dart';
import 'widgets/personality_preview.dart';
import 'widgets/preferences_section.dart';

/// Settings > AI Coach > Customize: everything about how the coach talks
/// (docs/coach-personality/ui-ux.md). Edits are a draft until Save; leaving with unsaved
/// changes asks first.
class CoachPersonalityScreen extends ConsumerStatefulWidget {
  const CoachPersonalityScreen({super.key});

  @override
  ConsumerState<CoachPersonalityScreen> createState() => CoachPersonalityScreenState();
}

class CoachPersonalityScreenState extends ConsumerState<CoachPersonalityScreen> {
  /// What is being edited: a built-in preset (`preset:<id>`) or a profile id.
  late String target;

  /// The personality being edited. For a preset it is an unsaved profile based on it.
  late PersonalityProfile draft;
  late PersonalityProfile original;
  late CoachIdentity global;
  late CoachIdentity originalGlobal;

  @override
  void initState() {
    super.initState();
    _load(ref.read(personalityProvider).activeId);
  }

  void _load(String id) {
    final settings = ref.read(personalityProvider);
    final notifier = ref.read(personalityProvider.notifier);
    target = id;
    final profile = settings.profiles.where((p) => p.id == id).firstOrNull;
    original =
        profile ??
        notifier.draftFrom(basePreset: id.startsWith('preset:') ? id.substring(7) : 'default');
    draft = original;
    global = originalGlobal = settings.global;
  }

  bool get isProfile => !target.startsWith('preset:');

  bool get dirty =>
      !draft.sameAs(original) || draft.name != original.name || global != originalGlobal;

  PersonalityPreset get preset => presetById(draft.basePreset);

  void update(PersonalityProfile next) => setState(() => draft = next);

  void updateGlobal(CoachIdentity next) => setState(() => global = next);

  Future<bool> confirmDiscard() async {
    if (!dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your changes to this personality are not saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep editing'),
          ),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Discard')),
        ],
      ),
    );
    return ok ?? false;
  }

  /// Edits another preset or profile, after asking about unsaved changes.
  Future<void> switchTo(String id) async {
    if (id == target || !await confirmDiscard()) return;
    setState(() => _load(id));
  }

  Future<void> save() async {
    final notifier = ref.read(personalityProvider.notifier);
    if (global != originalGlobal) await notifier.setGlobal(global);
    PersonalityProfile? saved = draft;
    if (!draft.sameAs(original) || draft.name != original.name || isProfile) {
      saved = await notifier.saveProfile(draft, activate: true);
    }
    if (!mounted) return;
    if (saved == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You have 20 profiles. Delete one to save another.')),
      );
      return;
    }
    setState(() => _load(saved!.id));
    announceCoach(context, saved.name);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Saved. Coach is now ${saved.name}.')));
  }

  void discard() => setState(() {
    draft = original;
    global = originalGlobal;
  });

  Future<void> restoreDefaults() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Restore ${preset.label} defaults?'),
        content: const Text('Sliders, options and your instructions go back to the preset.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    update(
      PersonalityProfile(
        id: draft.id,
        name: draft.name,
        basePreset: draft.basePreset,
        source: draft.source,
        createdAt: draft.createdAt,
      ),
    );
  }

  /// The editor's sections, in order (ui-ux.md). Each is its own widget.
  List<Widget> sections(bool readOnly) => [
    CollapsibleSection(
      key: const ValueKey('section-personality'),
      title: 'Personality',
      icon: Icons.tune,
      initiallyOpen: true,
      badge: draft.overrides.isEmpty
          ? null
          : '${draft.overrides.length} change${draft.overrides.length == 1 ? '' : 's'}',
      child: AttributeSliders(
        preset: preset,
        overrides: draft.overrides,
        enabled: !readOnly,
        onChanged: (o) => update(draft.copyWith(overrides: o)),
      ),
    ),
    CollapsibleSection(
      key: const ValueKey('section-preferences'),
      title: 'How the coach talks',
      icon: Icons.record_voice_over_outlined,
      badge: draft.preferences.isDefault ? null : 'changed',
      child: PreferencesSection(
        prefs: draft.preferences,
        enabled: !readOnly,
        onChanged: (p) => update(draft.copyWith(preferences: p)),
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(personalityProvider);
    final readOnly = settings.readOnly;
    final wide = Breakpoints.of(context) == WindowClass.expanded;
    final text = Theme.of(context).textTheme;
    final header = _Header(state: this, readOnly: readOnly);
    final preview = PersonalityPreview(
      key: ValueKey('preview-${draft.basePreset}'),
      preset: preset,
      edited: !draft.sameAs(PersonalityProfile(id: '', name: '', basePreset: draft.basePreset)),
    );
    final editor = [
      for (final s in sections(readOnly)) ...[s, const SizedBox(height: Spacing.lg)],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('restore-defaults'),
          onPressed: readOnly ? null : restoreDefaults,
          icon: const Icon(Icons.settings_backup_restore),
          label: Text('Restore ${preset.label} defaults'),
        ),
      ),
      Text(
        'Personality changes how your coach talks, not what it knows. Your coach is an AI and '
        "doesn't replace a qualified coach, doctor or physiotherapist.",
        style: text.bodySmall,
      ),
    ];
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirmDiscard() && context.mounted) {
          setState(() => draft = original);
          Navigator.of(context).pop();
        }
      },
      // Save stays in reach on a long page: a bar pinned under it.
      child: Scaffold(
        bottomNavigationBar: _SaveBar(state: this, readOnly: readOnly),
        body: PageScaffold(
          title: 'Coach personality',
          maxWidth: wide ? 1100 : 720,
          children: [
            if (settings.notice != null) ...[
              Text(settings.notice!, style: text.bodyMedium),
              const SizedBox(height: Spacing.md),
            ],
            header,
            const SizedBox(height: Spacing.lg),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: Column(children: editor)),
                  const SizedBox(width: Spacing.lg),
                  Expanded(flex: 2, child: preview),
                ],
              )
            else ...[
              preview,
              const SizedBox(height: Spacing.lg),
              ...editor,
            ],
          ],
        ),
      ),
    );
  }
}

/// Save and Discard, pinned to the bottom of the page.
class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.state, required this.readOnly});

  final CoachPersonalityScreenState state;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final dirty = state.dirty && !readOnly;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.sm),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  readOnly
                      ? 'Made by a newer version: changes are off.'
                      : dirty
                      ? 'Unsaved changes'
                      : 'Saved',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (dirty)
                TextButton(
                  key: const ValueKey('personality-discard'),
                  onPressed: state.discard,
                  child: const Text('Discard'),
                ),
              const SizedBox(width: Spacing.sm),
              FilledButton(
                key: const ValueKey('personality-save'),
                onPressed: dirty ? state.save : null,
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which personality is being edited, and a way to edit another.
class _Header extends ConsumerWidget {
  const _Header({required this.state, required this.readOnly});

  final CoachPersonalityScreenState state;
  final bool readOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(personalityProvider);
    final text = Theme.of(context).textTheme;
    final draft = state.draft;
    final items = [
      for (final p in settings.profiles)
        DropdownMenuEntry(
          value: p.id,
          label: p.name,
          leadingIcon: Icon(presetById(p.basePreset).icon),
        ),
      for (final p in kPersonalityPresets)
        DropdownMenuEntry(value: 'preset:${p.id}', label: p.label, leadingIcon: Icon(p.icon)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownMenu<String>(
          key: const ValueKey('personality-target'),
          label: const Text('Editing'),
          initialSelection: state.target,
          dropdownMenuEntries: items,
          onSelected: (id) => id == null ? null : state.switchTo(id),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          state.isProfile
              ? 'Profile based on ${state.preset.label}${state.dirty ? ' · unsaved changes' : ''}'
              : '${state.preset.label} preset. Saving a change creates the profile '
                    '"${draft.name}".',
          style: text.bodySmall,
        ),
      ],
    );
  }
}
