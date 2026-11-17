import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_mode.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';

/// F18: first screen after connecting. The last choice is highlighted and remembered.
class ModeScreen extends ConsumerWidget {
  const ModeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(appModeProvider);
    final health = ref.watch(healthProvider).valueOrNull;
    final liveOff = health != null && !health.supportsLive;
    final watchSupported = kIsWeb || defaultTargetPlatform == TargetPlatform.windows;
    Future<void> pick(AppMode mode) async {
      await ref.read(appModeProvider.notifier).set(mode);
      if (context.mounted) context.go(Routes.home);
    }

    return PageScaffold(
      title: 'How do you want to analyze?',
      children: [
        ModeCard(
          icon: Icons.upload_file,
          title: 'Upload clip',
          description:
              'Pick a recorded rally. The server processes it and shows full results, '
              'line calls and coaching notes.',
          selected: current == AppMode.upload,
          onTap: () => pick(AppMode.upload),
        ),
        const SizedBox(height: Spacing.lg),
        ModeCard(
          icon: Icons.videocam_outlined,
          title: 'Go live',
          description: liveOff
              ? 'This server is too old for live mode (clip record ${health.schemaVersion}). '
                    'Update the backend to use it.'
              : 'Point a camera at the court and see the shuttle, score and line calls while '
                    'you play. The session is saved to History when you stop.',
          selected: current == AppMode.live && !liveOff,
          onTap: liveOff ? null : () => pick(AppMode.live),
        ),
        const SizedBox(height: Spacing.lg),
        ModeCard(
          icon: Icons.play_circle_outline,
          title: 'Watch & Analyze',
          description: !watchSupported
              ? 'Watch & Analyze is currently available in Chrome and Windows.'
              : health?.watchVideo == true
              ? 'Watch a recorded rally while the server analyzes it frame by frame.'
              : 'Update the backend to use video-driven live analysis.',
          selected: current == AppMode.watch && health?.watchVideo == true && watchSupported,
          onTap: health?.watchVideo == true && watchSupported ? () => pick(AppMode.watch) : null,
        ),
      ],
    );
  }
}

class ModeCard extends StatelessWidget {
  const ModeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final bool selected;

  /// Null when the choice is not available; the card is shown greyed out.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: onTap == null ? scheme.surfaceContainerHighest : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Icon(
                    icon,
                    size: 32,
                    color: onTap == null ? scheme.outline : scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: Spacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: Spacing.xs),
                      Text(description),
                      if (selected) ...[
                        const SizedBox(height: Spacing.sm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Spacing.sm,
                            vertical: Spacing.xs,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary,
                            borderRadius: BorderRadius.circular(Radii.sm),
                          ),
                          child: Text(
                            'Last used',
                            style: Theme.of(
                              context,
                            ).textTheme.labelMedium?.copyWith(color: scheme.onPrimary),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// App bar action that switches between the upload and live screens.
class SwitchModeButton extends ConsumerWidget {
  const SwitchModeButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(appModeProvider) == AppMode.live;
    final available = ref.watch(liveAvailableProvider);
    return TextButton.icon(
      // A server without live mode keeps the user on upload.
      onPressed: live || available
          ? () => ref.read(appModeProvider.notifier).set(live ? AppMode.upload : AppMode.live)
          : null,
      icon: Icon(live ? Icons.upload_file : Icons.videocam_outlined),
      label: Text(live ? 'Upload clip' : 'Go live'),
    );
  }
}
