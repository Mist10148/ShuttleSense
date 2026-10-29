import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/calibration/calibration_screen.dart';
import '../../features/connect/connect_screen.dart';
import '../../features/history/history_screen.dart';
import '../../features/processing/processing_screen.dart';
import '../../features/results/results_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/upload/upload_screen.dart';
import '../config/server_config.dart';
import '../responsive/adaptive_shell.dart';

/// Routes from docs/ARCHITECTURE.md §4 (Navigation).
abstract final class Routes {
  static const connect = '/connect';
  static const home = '/';
  static const history = '/history';
  static const settings = '/settings';

  static String calibrate(String videoId) => '/videos/$videoId/calibrate';
  static String job(String jobId) => '/jobs/$jobId';
  static String results(String jobId) => '/jobs/$jobId/results';
}

final routerProvider = Provider<GoRouter>((ref) {
  // Re-run redirects when the saved server changes, without rebuilding the router.
  final refresh = ValueNotifier<int>(0);
  ref.listen(serverConfigProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final connected = ref.read(serverConfigProvider) != null;
      final atConnect = state.matchedLocation == Routes.connect;
      if (!connected && !atConnect) return Routes.connect;
      return null;
    },
    routes: [
      GoRoute(path: Routes.connect, builder: (context, state) => const ConnectScreen()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AdaptiveShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.home,
                builder: (context, state) => const UploadScreen(),
                routes: [
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
