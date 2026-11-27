import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/notifications/job_notifier.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/device/screen_awake.dart';
import 'package:shuttlesense_app/core/theme/app_skin.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/core/theme/skins/skin_theme.dart';
import 'package:shuttlesense_app/features/skins/fx/skin_fx_host.dart';
import 'package:shuttlesense_app/shared/widgets/skin/skin_scope.dart';
import 'package:shuttlesense_app/data/repositories/analysis_repository.dart';

import 'fakes/fake_api_client.dart';

/// Phone portrait, tablet, laptop (docs/ARCHITECTURE.md §4).
const phone = Size(360, 780);
const tablet = Size(800, 1100);
const laptop = Size(1280, 800);
const kSizes = {'phone': phone, 'tablet': tablet, 'laptop': laptop};

void setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Pumps [screen] at [size] with a [FakeApiClient] and a saved server, under a router that
/// records navigation: the returned list holds every location the screen went to.
Future<List<String>> pumpScreen(
  WidgetTester tester,
  Widget screen, {
  Size size = phone,
  FakeApiClient? api,
  Map<String, Object> prefs = const {},
  List<Override> overrides = const [],
  bool settle = true,
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  AppSkin? skin,
}) async {
  setSize(tester, size);
  SharedPreferences.setMockInitialValues({'server.baseUrl': 'http://fake:8000', ...prefs});
  final preferences = await SharedPreferences.getInstance();
  final visited = <String>[];
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => screen),
      GoRoute(
        path: '/:rest(.*)',
        builder: (_, state) {
          visited.add(state.uri.toString());
          return Scaffold(body: Text('route ${state.uri}'));
        },
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(api ?? FakeApiClient()),
        // The real notifier would call the notifications plugin, which tests do not have.
        jobNotifierProvider.overrideWithValue(const NoopJobNotifier()),
        screenAwakeProvider.overrideWithValue(FakeScreenAwake()),
        ...overrides,
      ],
      child: MaterialApp.router(
        theme: skin != null
            ? skinTheme(skin, brightness: brightness)
            : brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          // a theme other than Classic paints its backdrop, as in the app (docs/THEMES.md)
          child: skin != null ? SkinFxHost(child: SkinScope(child: child!)) : child!,
        ),
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return visited;
}
