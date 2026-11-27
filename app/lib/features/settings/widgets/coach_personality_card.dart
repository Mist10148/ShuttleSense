import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/tokens.dart';
import '../../../data/repositories/analysis_repository.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/status_pill.dart';
import '../../../shared/widgets/tactile.dart';
import '../../coach_personality/personality_notifier.dart';
import '../../coach_personality/personality_switcher_sheet.dart';
import '../../coach_personality/presets.dart';
import '../../coach_personality/widgets/personality_preview.dart';

/// Settings > AI Coach: pick how the coach talks in one tap; everything else is behind
/// Customize (docs/coach-personality/ui-ux.md, Settings card). A choice applies at once,
/// with Undo, like the Theme card.
class CoachPersonalityCard extends ConsumerStatefulWidget {
  const CoachPersonalityCard({super.key});

  @override
  ConsumerState<CoachPersonalityCard> createState() => _CoachPersonalityCardState();
}

class _CoachPersonalityCardState extends ConsumerState<CoachPersonalityCard> {
  bool _all = false;

  /// On a phone the grid starts with the first eight presets.
  static const _short = 8;

  void _choose(String activeId, String label) {
    final notifier = ref.read(personalityProvider.notifier);
    final before = ref.read(personalityProvider).activeId;
    if (before == activeId) return;
    notifier.activate(activeId);
    announceCoach(context, label);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Coach is now $label'),
          action: SnackBarAction(label: 'Undo', onPressed: () => notifier.activate(before)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(personalityProvider);
    final health = ref.watch(healthProvider).valueOrNull;
    final unsupported = health != null && !health.coachPersonality;
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final compact = Breakpoints.of(context) == WindowClass.compact;
    final keyWidth = compact ? 100.0 : 136.0;
    final active = settings.activeProfile;
    final preset = presetById(settings.activePresetId);
    final presets = compact && !_all
        ? kPersonalityPresets.take(_short).toList()
        : kPersonalityPresets;
    final enabled = !settings.readOnly;

    return SectionCard(
      title: 'AI Coach',
      icon: Icons.forum_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (unsupported) ...[
            const StatusPill(
              label: 'This server uses the standard coach voice',
              tone: PillTone.warning,
            ),
            const SizedBox(height: Spacing.sm),
          ],
          if (settings.notice != null) ...[
            Text(settings.notice!, style: text.bodyMedium),
            TextButton(
              onPressed: ref.read(personalityProvider.notifier).clearNotice,
              child: const Text('OK'),
            ),
          ],
          Text('Pick how your coach talks. You can change it any time.', style: muted),
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final p in presets)
                SizedBox(
                  width: keyWidth,
                  child: KeyCap(
                    key: ValueKey('coach-preset-${p.id}'),
                    selected: active == null && settings.activePresetId == p.id,
                    semanticLabel: '${p.label} coach personality',
                    tooltip: p.description,
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.sm,
                      vertical: Spacing.md,
                    ),
                    onTap: enabled && !unsupported
                        ? () => p.id == 'custom'
                              ? context.push(Routes.coachPersonality)
                              : _choose('preset:${p.id}', p.label)
                        : null,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(p.icon),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          p.label,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          style: text.labelLarge,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (compact)
            TextButton(
              key: const ValueKey('coach-show-all'),
              onPressed: () => setState(() => _all = !_all),
              child: Text(_all ? 'Show fewer' : 'Show all ${kPersonalityPresets.length}'),
            ),
          if (settings.profiles.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            Text('My profiles', style: text.titleSmall),
            const SizedBox(height: Spacing.xs),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final p in settings.profiles.take(3))
                  ChoiceChip(
                    key: ValueKey('coach-profile-${p.id}'),
                    avatar: Icon(presetById(p.basePreset).icon, size: 18),
                    label: Text(p.name),
                    selected: settings.activeId == p.id,
                    onSelected: enabled ? (_) => _choose(p.id, p.name) : null,
                  ),
                if (settings.profiles.length > 3)
                  ActionChip(
                    label: Text('+${settings.profiles.length - 3} more'),
                    onPressed: () => showPersonalitySwitcher(context),
                  ),
              ],
            ),
          ],
          const SizedBox(height: Spacing.md),
          Text(
            active == null
                ? '${preset.label} · ${preset.description}'
                : '${active.name} · based on ${preset.label}',
            key: const ValueKey('coach-description'),
            style: text.bodyMedium,
          ),
          const SizedBox(height: Spacing.sm),
          PersonalityPreview(
            key: ValueKey('coach-preview-${preset.id}'),
            preset: preset,
            edited: active != null,
          ),
          const SizedBox(height: Spacing.sm),
          // Below the content, not in the card's title row, so it fits at large text sizes.
          OutlinedButton.icon(
            key: const ValueKey('coach-customize'),
            onPressed: () => context.push(Routes.coachPersonality),
            icon: const Icon(Icons.tune),
            label: const Text('Customize'),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Personality changes how your coach talks, not what it knows. Your coach is an AI '
            "and doesn't replace a qualified coach, doctor or physiotherapist.",
            style: muted,
          ),
        ],
      ),
    );
  }
}
