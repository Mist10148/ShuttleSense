import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/tokens.dart';
import '../../../data/repositories/analysis_repository.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/status_pill.dart';
import '../../../shared/widgets/tactile.dart';
import '../../../ui/depth.dart';
import '../../coach_personality/personality_notifier.dart';
import '../../coach_personality/personality_switcher_sheet.dart';
import '../../coach_personality/preset_groups.dart';
import '../../coach_personality/presets.dart';
import '../../coach_personality/widgets/personality_preview.dart';

/// Settings > AI Coach: pick how the coach talks in one tap; everything else is behind
/// Customize (docs/coach-personality/ui-ux.md, Settings card). A choice applies at once,
/// with Undo, like the Theme card.
///
/// The card leads with the coach in use, then the presets in four named groups of four
/// (preset_groups.dart), each key with a short tagline. A wide card shows every group as a
/// row; a narrow one shows one group at a time, starting with the active preset's.
class CoachPersonalityCard extends ConsumerStatefulWidget {
  const CoachPersonalityCard({super.key});

  @override
  ConsumerState<CoachPersonalityCard> createState() => _CoachPersonalityCardState();
}

class _CoachPersonalityCardState extends ConsumerState<CoachPersonalityCard> {
  /// The group shown on a narrow card; null: the active preset's group.
  String? _group;

  /// Below this card width the groups are shown one at a time.
  static const _wide = 560.0;

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
          // Goes away by itself: an action would otherwise keep it up on every screen.
          persist: false,
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
    final active = settings.activeProfile;
    final preset = presetById(settings.activePresetId);
    final enabled = !settings.readOnly && !unsupported;

    Widget key(PersonalityPreset p) => _PresetKey(
      preset: p,
      selected: active == null && settings.activePresetId == p.id,
      onTap: enabled ? () => _choose('preset:${p.id}', p.label) : null,
    );

    return SectionCard(
      title: 'AI Coach',
      icon: Icons.forum_outlined,
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= _wide;
          // Large text on a narrow card: one key per row, so names never break mid-word.
          final perRow = !wide && MediaQuery.textScalerOf(context).scale(10) >= 15 ? 1 : 2;
          final shown = _group == null
              ? groupOf(preset.id)
              : kPresetGroups.firstWhere((g) => g.id == _group);
          return Column(
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
              _CurrentCoach(
                icon: preset.icon,
                title: active == null ? preset.label : active.name,
                detail: active == null ? preset.description : 'based on ${preset.label}',
                wide: wide,
                stacked: perRow == 1,
              ),
              const SizedBox(height: Spacing.lg),
              Text('Pick how your coach talks. You can change it any time.', style: muted),
              const SizedBox(height: Spacing.md),
              if (wide)
                for (final group in kPresetGroups) ...[
                  _GroupHeading(group: group),
                  const SizedBox(height: Spacing.xs),
                  _KeyRow(children: [for (final id in group.presetIds) key(presetById(id))]),
                  const SizedBox(height: Spacing.md),
                ]
              else ...[
                // One group at a time keeps a phone card short (it was 17 keys tall). Chips
                // wrap, so the group names stay whole at any width and text size.
                Wrap(
                  key: const ValueKey('coach-groups'),
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final g in kPresetGroups)
                      ChoiceChip(
                        key: ValueKey('coach-group-chip-${g.id}'),
                        label: Text(g.label),
                        selected: g.id == shown.id,
                        onSelected: (_) => setState(() => _group = g.id),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.sm),
                Text(shown.blurb, key: const ValueKey('coach-group-blurb'), style: muted),
                const SizedBox(height: Spacing.sm),
                for (var i = 0; i < shown.presetIds.length; i += perRow) ...[
                  _KeyRow(
                    children: [
                      for (final id in shown.presetIds.skip(i).take(perRow)) key(presetById(id)),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
                const SizedBox(height: Spacing.xs),
              ],
              _BuildYourOwn(onTap: enabled ? () => context.push(Routes.coachPersonality) : null),
              if (settings.profiles.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
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
                        onSelected: settings.readOnly ? null : (_) => _choose(p.id, p.name),
                      ),
                    if (settings.profiles.length > 3)
                      ActionChip(
                        label: Text('+${settings.profiles.length - 3} more'),
                        onPressed: () => showPersonalitySwitcher(context),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: Spacing.lg),
              PersonalityPreview(
                key: ValueKey('coach-preview-${preset.id}'),
                preset: preset,
                edited: active != null,
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                'Personality changes how your coach talks, not what it knows. Your coach is an '
                "AI and doesn't replace a qualified coach, doctor or physiotherapist.",
                style: muted,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The coach in use: its icon in a sunken well, its name and what it is like, and
/// Customize. Beside each other on a wide card; Customize goes underneath on a narrow one,
/// so the description keeps the width at large text sizes.
class _CurrentCoach extends StatelessWidget {
  const _CurrentCoach({
    required this.icon,
    required this.title,
    required this.detail,
    required this.wide,
    this.stacked = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool wide;

  /// Icon above the text: large text on a narrow card needs the full width.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final customize = OutlinedButton.icon(
      key: const ValueKey('coach-customize'),
      onPressed: () => context.push(Routes.coachPersonality),
      icon: const Icon(Icons.tune),
      label: const Text('Customize'),
    );
    final well = InsetBox(
      radius: Radii.md,
      padding: const EdgeInsets.all(Spacing.md),
      child: Icon(icon, size: 28, color: theme.colorScheme.primary),
    );
    final about = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your coach',
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        Semantics(
          liveRegion: true,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: title,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: ' · $detail'),
              ],
            ),
            key: const ValueKey('coach-description'),
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
    final summary = stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              well,
              const SizedBox(height: Spacing.sm),
              about,
            ],
          )
        : Row(
            children: [
              well,
              const SizedBox(width: Spacing.md),
              Expanded(child: about),
            ],
          );
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          summary,
          const SizedBox(height: Spacing.sm),
          customize,
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: summary),
        const SizedBox(width: Spacing.md),
        customize,
      ],
    );
  }
}

class _GroupHeading extends StatelessWidget {
  const _GroupHeading({required this.group});

  final PresetGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: group.label, style: theme.textTheme.titleSmall),
            TextSpan(
              text: '  ${group.blurb}',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        key: ValueKey('coach-group-${group.id}'),
      ),
    );
  }
}

/// Keys of equal width side by side: rows always fill, so no lone key is left hanging.
class _KeyRow extends StatelessWidget {
  const _KeyRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: Spacing.sm),
          Expanded(child: children[i]),
        ],
      ],
    );
  }
}

class _PresetKey extends StatelessWidget {
  const _PresetKey({required this.preset, required this.selected, required this.onTap});

  final PersonalityPreset preset;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagline = kPresetTaglines[preset.id];
    return ConstrainedBox(
      // Same height in a row whatever the tagline's length.
      constraints: const BoxConstraints(minHeight: 104),
      child: KeyCap(
        key: ValueKey('coach-preset-${preset.id}'),
        selected: selected,
        semanticLabel:
            '${preset.label} coach personality${tagline == null ? '' : ': $tagline'}'
            '${selected ? ', selected' : ''}',
        tooltip: preset.description,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.md),
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(preset.icon),
            const SizedBox(height: Spacing.xs),
            Text(
              preset.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: theme.textTheme.labelLarge,
            ),
            if (tagline != null)
              Text(
                tagline,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Custom sits apart from the presets: it opens the editor instead of picking a voice.
class _BuildYourOwn extends StatelessWidget {
  const _BuildYourOwn({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final custom = presetById('custom');
    return KeyCap(
      key: const ValueKey('coach-preset-custom'),
      semanticLabel: 'Build your own coach personality',
      tooltip: custom.description,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.md),
      onTap: onTap,
      child: Row(
        children: [
          Icon(custom.icon),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Build your own', style: theme.textTheme.labelLarge),
                Text(
                  kPresetTaglines['custom']!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
  }
}
