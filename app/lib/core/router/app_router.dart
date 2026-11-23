import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/repositories/analysis_repository.dart';
import '../../features/calibration/calibration_screen.dart';
import '../../features/chat/chat_screen.dart';
import '../../features/coach/coach_screen.dart';
import '../../features/connect/connect_screen.dart';
import '../../features/history/history_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/live/live_screen.dart';
import '../../features/mode/mode_screen.dart';
import '../../features/processing/processing_screen.dart';
import '../../features/practice/practice_screen.dart';
import '../../features/results/results_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/styleguide/styleguide_screen.dart';
import '../../features/upload/upload_screen.dart';
import '../../features/watch/watch_screen.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../config/app_mode.dart';
import '../config/server_config.dart';
import '../responsive/adaptive_shell.dart';
import '../theme/tokens.dart';

/// Routes from docs/ARCHITECTURE.md §4 (Navigation).
abstract final class Routes {
  static const connect = '/connect';

  /// Home, the landing page: start an analysis, recent analyses, stroke mix.
  static const dashboard = '/dashboard';
  static const mode = '/mode';
  static const home = '/';
  static const history = '/history';
  static const settings = '/settings';
  static const styleguide = '/styleguide';
  static const coach = '/coach';

  static String calibrate(String videoId) => '/videos/$videoId/calibrate';
  static String job(String jobId) => '/jobs/$jobId';
  static String results(String jobId) => '/jobs/$jobId/results';
  static String chat(String jobId) => '/jobs/$jobId/results/chat';
  static String practice(String jobId) => '/practice/$jobId';
}

final routerProvider = Provider<GoRouter>((ref) {
  // Re-run redirects when the saved server changes, without rebuilding the router.
  final refresh = ValueNotifier<int>(0);
  ref.listen(serverConfigProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.dashboard,
    refreshListenable: refresh,
    errorBuilder: (context, state) => Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(Spacing.lg),
              child: PageHeader(title: 'Page not found', showBack: false),
            ),
            Expanded(
              child: MessageView(
                icon: Icons.search_off,
                message: 'Page not found',
                detail: 'Nothing lives at ${state.uri}.',
                action: FilledButton(
                  onPressed: () => context.go(Routes.dashboard),
                  child: const Text('Go to Home'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
    redirect: (context, state) {
      final connected = ref.read(serverConfigProvider) != null;
      // The styleguide needs no server, so the design can be reviewed on any machine.
      final open = {Routes.connect, Routes.styleguide}.contains(state.matchedLocation);
      if (!connected && !open) return Routes.connect;
      return null;
    },
    routes: [
      GoRoute(path: Routes.connect, builder: (context, state) => const ConnectScreen()),
      GoRoute(path: Routes.styleguide, builder: (context, state) => const StyleguideScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AdaptiveShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: Routes.dashboard, builder: (context, state) => const HomeScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.home,
                // The Analyze tab follows the remembered mode (F18).
                builder: (context, state) => Consumer(
                  builder: (context, ref, _) => switch (ref.watch(appModeProvider)) {
                    AppMode.watch => const WatchScreen(),
                    AppMode.practice => const PracticeScreen(),
                    AppMode.live when ref.watch(liveAvailableProvider) => const LiveScreen(),
                    _ => const UploadScreen(),
                  },
                ),
                routes: [
                  // The mode chooser is the Analyze tab's landing view, inside the rail.
                  GoRoute(path: 'mode', builder: (context, state) => const ModeScreen()),
                  GoRoute(
                    path: 'practice/:jobId',
                    builder: (context, state) =>
                        PracticeScreen(jobId: state.pathParameters['jobId']!),
                  ),
                  GoRoute(
                    path: 'videos/:videoId/calibrate',
                    builder: (context, state) =>
                        CalibrationScreen(videoId: state.pathParameters['videoId']!),
                  ),
                  GoRoute(
                    path: 'jobs/:jobId',
                    builder: (context, state) =>
                        ProcessingScreen(jobId: state.pathParameters['jobId']!),
                    routes: [
                      GoRoute(
                        path: 'results',
                        builder: (context, state) =>
                            ResultsScreen(jobId: state.pathParameters['jobId']!),
                        routes: [
                          GoRoute(
                            path: 'chat',
                            builder: (context, state) =>
                                ChatScreen(jobId: state.pathParameters['jobId']!),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: Routes.history, builder: (context, state) => const HistoryScreen()),
              // The general coach opens from History, inside the app frame like every page.
              GoRoute(path: Routes.coach, builder: (context, state) => const CoachScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: Routes.settings, builder: (context, state) => const SettingsScreen()),
            ],
          ),
        ],
      ),
    ],
  );
});
