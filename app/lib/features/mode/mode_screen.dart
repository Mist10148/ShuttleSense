import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_mode.dart';
import '../../core/router/app_router.dart';
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
        const SizedBox(height: 16),
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
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
                Icon(icon, size: 40, color: onTap == null ? scheme.outline : scheme.primary),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(description),
                      if (selected) ...[
                        const SizedBox(height: 8),
                        Text('Last used', style: TextStyle(color: scheme.primary)),
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
    return TextButton.icon(
      onPressed: () => ref.read(appModeProvider.notifier).set(live ? AppMode.upload : AppMode.live),
      icon: Icon(live ? Icons.upload_file : Icons.videocam_outlined),
      label: Text(live ? 'Upload clip' : 'Go live'),
    );
  }
}
