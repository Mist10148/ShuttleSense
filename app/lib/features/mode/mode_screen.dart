import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_mode.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';

/// F18: the Analyze tab's landing view and the one place the mode is picked. The last choice
/// carries a "Last used" badge and is remembered.
class ModeScreen extends StatelessWidget {
  const ModeScreen({super.key});

  @override
  Widget build(BuildContext context) => const PageScaffold(
    title: 'How do you want to analyze?',
    showBack: false,
    maxWidth: 1080,
    children: [ModeChoices(detailed: true)],
  );
}

/// The three ways to analyze as pastel cards: Upload clip (lavender), Go live (sky), Watch &
/// Analyze (mint). [detailed] adds the longer description and what each one needs (the mode
/// chooser); without it each card has one line (Home). Picking one saves it and opens Analyze.
class ModeChoices extends ConsumerWidget {
  const ModeChoices({super.key, this.detailed = false});

  final bool detailed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AppPalette.of(context);
    final current = ref.watch(appModeProvider);
    final health = ref.watch(healthProvider).valueOrNull;
    final liveOff = health != null && !health.supportsLive;
    final watchSupported = kIsWeb || defaultTargetPlatform == TargetPlatform.windows;
    final watchOn = health?.watchVideo == true && watchSupported;
    Future<void> pick(AppMode mode) async {
      await ref.read(appModeProvider.notifier).set(mode);
      if (context.mounted) context.go(Routes.home);
    }

    String? lastUsed(AppMode mode, {bool available = true}) =>
        current == mode && available ? 'Last used' : null;

    return CardGrid(
      minWidth: detailed ? 280 : 220,
      children: [
        PastelActionCard(
          color: p.lavender,
          icon: Icons.upload_file,
          title: 'Upload clip',
          description: detailed
              ? 'Pick a recorded rally. The server processes it and shows full results, '
                    'line calls and coaching notes.'
              : 'Analyze a recorded rally.',
          footnote: detailed ? 'You need: a recorded video file (MP4, MOV or AVI)' : null,
          badge: lastUsed(AppMode.upload),
          onTap: () => pick(AppMode.upload),
        ),
        PastelActionCard(
          color: p.sky,
          icon: Icons.videocam_outlined,
          title: 'Go live',
          description: liveOff
              ? 'This server is too old for live mode (clip record ${health.schemaVersion}). '
                    'Update the backend to use it.'
              : detailed
              ? 'Point a camera at the court and see the shuttle, score and line calls while '
                    'you play. The session is saved to History when you stop.'
              : 'Use a camera at the court.',
          footnote: detailed ? 'You need: a camera pointed at the court' : null,
          badge: lastUsed(AppMode.live, available: !liveOff),
          onTap: liveOff ? null : () => pick(AppMode.live),
        ),
        PastelActionCard(
          color: p.mint,
          icon: Icons.play_circle_outline,
          title: 'Watch & Analyze',
          description: !watchSupported
              ? 'Watch & Analyze is currently available in Chrome and Windows.'
              : health?.watchVideo != true
              ? 'Update the backend to use video-driven live analysis.'
              : detailed
              ? 'Watch a recorded rally while the server analyzes it frame by frame.'
              : 'Play a video while it is analyzed.',
          footnote: detailed
              ? 'You need: a recorded video file, in Chrome or the Windows app'
              : null,
          badge: lastUsed(AppMode.watch, available: watchOn),
          onTap: watchOn ? () => pick(AppMode.watch) : null,
        ),
      ],
    );
  }
}

/// Page action that returns to the mode chooser, the one place the mode is picked.
class ChangeModeButton extends StatelessWidget {
  const ChangeModeButton({super.key});

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => context.go(Routes.mode),
    icon: const Icon(Icons.swap_horiz),
    label: const Text('Change mode'),
  );
}
