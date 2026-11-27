import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import 'personality_notifier.dart';
import 'presets.dart';

/// The coach's current personality in the chat's app bar; tapping it opens a quick switcher
/// (docs/coach-personality/ui-ux.md, Save and apply behaviour).
class PersonalitySwitcherButton extends ConsumerWidget {
  const PersonalitySwitcherButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(personalityProvider);
    final label = ref.watch(activePersonalityLabelProvider);
    return IconButton(
      key: const ValueKey('personality-switcher'),
      tooltip: 'Coach personality: $label',
      icon: Icon(presetById(settings.activePresetId).icon),
      onPressed: () => showPersonalitySwitcher(context),
    );
  }
}

/// Tells screen readers the coach's voice changed: a snackbar can be missed.
void announceCoach(BuildContext context, String label) {
  SemanticsService.sendAnnouncement(
    View.of(context),
    'Coach is now $label',
    Directionality.of(context),
  );
}

Future<void> showPersonalitySwitcher(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (context) => const _SwitcherSheet(),
);

class _SwitcherSheet extends ConsumerWidget {
  const _SwitcherSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(personalityProvider);
    final notifier = ref.read(personalityProvider.notifier);
    final text = Theme.of(context).textTheme;

    void pick(String? activeId) {
      if (activeId == null || settings.readOnly) return;
      final label = activeId.startsWith('preset:')
          ? presetById(activeId.substring('preset:'.length)).label
          : settings.profiles.firstWhere((p) => p.id == activeId).name;
      notifier.activate(activeId);
      announceCoach(context, label);
      Navigator.of(context).pop();
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: RadioGroup<String>(
          groupValue: settings.activeId,
          onChanged: pick,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.lg),
            children: [
              Semantics(header: true, child: Text('Coach personality', style: text.titleMedium)),
              const SizedBox(height: Spacing.xs),
              Text(
                'Changes how the coach talks from the next answer. The conversation stays.',
                style: text.bodySmall,
              ),
              if (settings.profiles.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                Text('My profiles', style: text.labelLarge),
                for (final p in settings.profiles)
                  RadioListTile<String>(
                    key: ValueKey('switch-${p.id}'),
                    value: p.id,
                    enabled: !settings.readOnly,
                    secondary: Icon(presetById(p.basePreset).icon),
                    title: Text(p.name),
                    subtitle: Text('${presetById(p.basePreset).label} · edited'),
                  ),
              ],
              const SizedBox(height: Spacing.md),
              Text('Presets', style: text.labelLarge),
              for (final p in kPersonalityPresets)
                if (p.id != 'custom')
                  RadioListTile<String>(
                    key: ValueKey('switch-preset-${p.id}'),
                    value: 'preset:${p.id}',
                    enabled: !settings.readOnly,
                    secondary: Icon(p.icon),
                    title: Text(p.label),
                    subtitle: Text(p.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
