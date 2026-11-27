import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_skin.dart';
import '../../core/theme/skins/skin_decor.dart';
import '../../core/theme/skins/skin_theme.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/skin/skin_backdrop.dart';
import '../../shared/widgets/status_pill.dart';
import '../../shared/widgets/tactile.dart';
import '../../ui/depth.dart';

/// One theme, side by side with the others: the main parts of the design system drawn in
/// every theme at once (docs/THEMES.md). The styleguide (`/styleguide`) shows Classic; this
/// page shows all of them, Classic in light and dark, so a change can be checked everywhere.
class ThemeGalleryScreen extends StatelessWidget {
  const ThemeGalleryScreen({super.key});

  /// Every theme and brightness the gallery draws.
  static const variants = [
    (AppSkin.classic, Brightness.light),
    (AppSkin.classic, Brightness.dark),
    (AppSkin.backrooms, Brightness.light),
    (AppSkin.deniaLight, Brightness.light),
    (AppSkin.deniaDark, Brightness.dark),
  ];

  @override
  Widget build(BuildContext context) {
    final gutter = Breakpoints.gutter(Breakpoints.of(context));
    return Scaffold(
      appBar: AppBar(title: const Text('Theme gallery')),
      body: ListView(
        padding: EdgeInsets.all(gutter),
        children: [
          Text(
            'Every theme at once. Decoration is drawn behind each panel as it is behind pages.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: Spacing.lg),
          LayoutBuilder(
            builder: (context, box) {
              const preferred = 360.0;
              final width = box.maxWidth < preferred * 2 + Spacing.lg ? box.maxWidth : preferred;
              return Wrap(
                spacing: Spacing.lg,
                runSpacing: Spacing.lg,
                children: [
                  for (final (skin, brightness) in variants)
                    SizedBox(
                      key: ValueKey('gallery-${skin.name}-${brightness.name}'),
                      width: width,
                      child: _Panel(skin: skin, brightness: brightness),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.skin, required this.brightness});

  final AppSkin skin;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final theme = skinTheme(skin, brightness: brightness);
    final name = skin == AppSkin.classic
        ? 'Classic (${brightness == Brightness.dark ? 'Dark' : 'Light'})'
        : skin.label;
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final p = AppPalette.of(context);
          return ClipRRect(
            borderRadius: BorderRadius.circular(Radii.lg),
            child: Stack(
              children: [
                Positioned.fill(
                  child: SkinBackdrop(
                    decor: SkinDecor.of(context),
                    fx: const SkinFxSettings(),
                    base: p.page,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(Spacing.lg),
                  child: Semantics(
                    container: true,
                    label: '$name theme preview',
                    child: _Parts(name: name),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Parts extends StatelessWidget {
  const _Parts({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    void nothing() {}
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(name, style: text.titleLarge),
        const SizedBox(height: Spacing.md),
        SectionCard(
          title: 'Card',
          icon: Icons.palette_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Body text on a card.', style: text.bodyMedium),
              Text('Muted helper text.', style: muted),
              const SizedBox(height: Spacing.md),
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  KeyCap(
                    onTap: nothing,
                    selected: true,
                    padding: const EdgeInsets.all(Spacing.md),
                    child: const Text('Selected'),
                  ),
                  KeyCap(
                    onTap: nothing,
                    padding: const EdgeInsets.all(Spacing.md),
                    child: const Text('Key'),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  FilledButton(onPressed: nothing, child: const Text('Primary')),
                  OutlinedButton(onPressed: nothing, child: const Text('Secondary')),
                ],
              ),
              const SizedBox(height: Spacing.md),
              DepthSegmented<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('One')),
                  ButtonSegment(value: 1, label: Text('Two')),
                ],
                selected: const {0},
                onSelectionChanged: (_) {},
              ),
              TactileSwitchTile(
                title: const Text('Switch'),
                value: true,
                onChanged: (_) {},
                contentPadding: EdgeInsets.zero,
              ),
              Slider(value: 0.6, onChanged: (_) {}),
              const Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  StatusPill(label: 'Good', tone: PillTone.good),
                  StatusPill(label: 'Info', tone: PillTone.info),
                  StatusPill(label: 'Warning', tone: PillTone.warning),
                  StatusPill(label: 'Bad', tone: PillTone.bad),
                ],
              ),
              const SizedBox(height: Spacing.md),
              InsetBox(
                padding: const EdgeInsets.all(Spacing.md),
                child: Text('A sunken well.', style: text.bodyMedium),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
