import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/server_config.dart';
import '../../core/notifications/job_notifier.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/theme_mode.dart';
import '../../data/api_client.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/disclaimers.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/status_pill.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/tactile.dart';
import 'widgets/coach_personality_card.dart';
import 'widgets/theme_picker_card.dart';

/// Settings grouped as Connection, Appearance, Notifications, Privacy & data and About. The
/// analysis mode is not here: the mode chooser on the Analyze tab is its one home.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final config = ref.watch(serverConfigProvider);
    final health = ref.watch(healthProvider);
    final chatOn = health.valueOrNull?.chatAvailable == true;
    return PageScaffold(
      title: 'Settings',
      children: [
        SectionCard(
          title: 'Connection',
          icon: Icons.dns_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(config?.baseUrl ?? 'Not connected', style: theme.textTheme.bodyLarge),
              const SizedBox(height: Spacing.sm),
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  health.when(
                    loading: () => const StatusPill(label: 'Checking…'),
                    error: (_, _) => const StatusPill(label: 'Offline', tone: PillTone.bad),
                    data: (_) => const StatusPill(label: 'Online', tone: PillTone.good),
                  ),
                  ?health.when(
                    loading: () => null,
                    error: (e, _) => Text(e is ApiException ? e.message : '$e', style: muted),
                    data: (h) => Text(
                      'v${h.version} · schema ${h.schemaVersion} · ${h.device.toUpperCase()}',
                      style: muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.lg),
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => ref.invalidate(healthProvider),
                    icon: const Icon(Icons.network_check),
                    label: const Text('Test connection'),
                  ),
                  // The connect screen validates the address and checks the server before
                  // saving it, so changing the server goes there.
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
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: 'Appearance',
          icon: Icons.palette_outlined,
          child: DepthSegmented<ThemeMode>(
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
        const ThemePickerCard(),
        const SizedBox(height: Spacing.lg),
        const CoachPersonalityCard(),
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: 'Notifications',
          icon: Icons.notifications_none,
          child: TactileSwitchTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Notify when an analysis finishes'),
            subtitle: const Text('Only while the app is in the background'),
            value: ref.watch(notifyWhenDoneProvider),
            onChanged: (on) => ref.read(notifyWhenDoneProvider.notifier).set(on),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: 'Privacy & data',
          icon: Icons.shield_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Bullet('Videos and live camera frames go only to your ShuttleSense server.'),
              const _Bullet(
                'Coach chat sends a text summary of a session and your questions to the Claude '
                'API. No video, frames or images are sent.',
              ),
              const _Bullet('Delete an analysis, or its video too, from History.'),
              const SizedBox(height: Spacing.sm),
              Wrap(
                spacing: Spacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusPill(
                    label: 'Coach chat: ${chatOn ? 'on' : 'off'}',
                    tone: chatOn ? PillTone.good : PillTone.neutral,
                  ),
                  if (!chatOn)
                    TextButton(
                      onPressed: () => _showInfo(
                        context,
                        'Turning on coach chat',
                        'Coach chat runs on the server. Whoever runs the backend sets '
                            'SHUTTLESENSE_ANTHROPIC_API_KEY in its environment and restarts it '
                            '(docs/SETUP.md). The key never goes into the app.\n\n$kChatPrivacy',
                      ),
                      child: const Text('How to enable'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        SectionCard(
          title: 'About',
          icon: Icons.info_outline,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ShuttleSense analyzes badminton singles and doubles rallies: shuttle tracking, '
                'pose, stroke classification and court analytics. Speed, in/out and score are '
                'estimates.',
              ),
              const SizedBox(height: Spacing.sm),
              Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  TextButton.icon(
                    onPressed: () =>
                        _showInfo(context, 'Disclaimer', '$kLineCallNote\n\n$kCoachingDisclaimer'),
                    icon: const Icon(Icons.gavel_outlined),
                    label: const Text('Disclaimer'),
                  ),
                  TextButton.icon(
                    onPressed: () =>
                        showLicensePage(context: context, applicationName: 'ShuttleSense'),
                    icon: const Icon(Icons.description_outlined),
                    label: const Text('Licenses'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _showInfo(BuildContext context, String title, String body) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SingleChildScrollView(child: Text(body)),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
  ),
);

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Spacing.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('•  '),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
