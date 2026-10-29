import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/server_config.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme_mode.dart';
import '../../data/api_client.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/section_card.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(serverConfigProvider);
    final health = ref.watch(healthProvider);
    return PageScaffold(
      title: 'Settings',
      children: [
        SectionCard(
          title: 'Server',
          trailing: IconButton(
            tooltip: 'Check again',
            onPressed: () => ref.invalidate(healthProvider),
            icon: const Icon(Icons.refresh),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(config?.baseUrl ?? 'Not connected'),
                subtitle: health.when(
                  loading: () => const Text('Checking…'),
                  error: (e, _) => Text(e is ApiException ? e.message : '$e'),
                  data: (h) => Text(
                    'Online · v${h.version} · schema ${h.schemaVersion} · ${h.device.toUpperCase()}',
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await ref.read(serverConfigProvider.notifier).clear();
                  if (context.mounted) context.go(Routes.connect);
                },
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Change server'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Appearance',
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                label: Text('System'),
                icon: Icon(Icons.brightness_auto),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                label: Text('Light'),
                icon: Icon(Icons.light_mode),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text('Dark'),
                icon: Icon(Icons.dark_mode),
              ),
            ],
            selected: {ref.watch(themeModeProvider)},
            onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
          ),
        ),
        const SizedBox(height: 16),
        const SectionCard(
          title: 'About',
          child: Text(
            'ShuttleSense analyzes badminton singles rallies: shuttle tracking, pose, stroke '
            'classification and court analytics. Speed, in/out and score are estimates. '
            'Form feedback is heuristic guidance, not professional coaching.',
          ),
        ),
      ],
    );
  }
}
