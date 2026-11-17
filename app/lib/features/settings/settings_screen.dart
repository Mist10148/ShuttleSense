import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_mode.dart';
import '../../core/config/server_config.dart';
import '../../core/notifications/job_notifier.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme_mode.dart';
import '../../data/api_client.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/disclaimers.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/section_card.dart';
import '../../core/theme/tokens.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(serverConfigProvider);
    final health = ref.watch(healthProvider);
    final liveAvailable = ref.watch(liveAvailableProvider);
    final watchAvailable =
        health.valueOrNull?.watchVideo == true &&
        (kIsWeb || defaultTargetPlatform == TargetPlatform.windows);
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
        const SizedBox(height: Spacing.lg),
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
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: 'Analysis mode',
          child: SegmentedButton<AppMode>(
            segments: [
              const ButtonSegment(
                value: AppMode.upload,
                label: Text('Upload clip'),
                icon: Icon(Icons.upload_file),
              ),
              ButtonSegment(
                value: AppMode.live,
                label: const Text('Go live'),
                icon: const Icon(Icons.videocam_outlined),
                enabled: liveAvailable,
                tooltip: liveAvailable ? null : 'This server is too old for live mode',
              ),
              ButtonSegment(
                value: AppMode.watch,
                label: const Text('Watch video'),
                icon: const Icon(Icons.play_circle_outline),
                enabled: watchAvailable,
                tooltip: watchAvailable
                    ? null
                    : 'Watch needs the Windows or web app and a server that supports it',
              ),
            ],
            // Default disabled text (onSurface at 38%) is 2.3:1 on the card; keep 4.5:1 (T4.11).
            style: SegmentedButton.styleFrom(
              disabledForegroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
              disabledIconColor: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            selected: {ref.watch(appModeProvider)},
            onSelectionChanged: (s) => ref.read(appModeProvider.notifier).set(s.first),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: 'Notifications',
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notify when an analysis finishes'),
            subtitle: const Text('Only while the app is in the background'),
            value: ref.watch(notifyWhenDoneProvider),
            onChanged: (on) => ref.read(notifyWhenDoneProvider.notifier).set(on),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: 'Privacy',
          child: Text(
            'Videos and live camera frames go only to your ShuttleSense server. '
            '$kChatPrivacy Coach chat on this server: '
            '${health.valueOrNull?.chatAvailable == true ? 'on' : 'off'}.',
          ),
        ),
        const SizedBox(height: Spacing.lg),
        const SectionCard(
          title: 'About',
          child: Text(
            'ShuttleSense analyzes badminton singles and doubles rallies: shuttle tracking, pose, '
            'stroke classification and court analytics. Speed, in/out and score are estimates; '
            '$kLineCallNote $kCoachingDisclaimer',
          ),
        ),
      ],
    );
  }
}
