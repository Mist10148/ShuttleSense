import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/device/screen_awake.dart';
import 'package:shuttlesense_app/core/notifications/job_notifier.dart';
import 'package:shuttlesense_app/core/router/app_router.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/repositories/analysis_repository.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

Future<GoRouter> _pumpRouter(
  WidgetTester tester, {
  Map<String, Object> saved = const {},
  FakeApiClient? api,
}) async {
  setSize(tester, laptop);
  SharedPreferences.setMockInitialValues({'server.baseUrl': 'http://fake:8000', ...saved});
  final prefs = await SharedPreferences.getInstance();
  late GoRouter router;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(api ?? FakeApiClient()),
        jobNotifierProvider.overrideWithValue(const NoopJobNotifier()),
        screenAwakeProvider.overrideWithValue(FakeScreenAwake()),
      ],
      child: Consumer(
        builder: (context, ref, _) {
          router = ref.watch(routerProvider);
          return MaterialApp.router(theme: AppTheme.light(), routerConfig: router);
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('an unknown path shows the 404 page, and Go to Home leaves it', (tester) async {
    final router = await _pumpRouter(tester);
    router.go('/no/such/page');
    await tester.pumpAndSettle();
    expect(find.text('Page not found'), findsWidgets);
    expect(find.textContaining('/no/such/page'), findsOneWidget);

    await tester.tap(find.text('Go to Home'));
    await tester.pumpAndSettle();
    expect(find.text('Page not found'), findsNothing);
    expect(tester.takeException(), isNull);
    // Unmount the scope so its polling timers are cancelled before the test ends.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('legacy Upload preference and calibration link lead to the mode chooser', (
    tester,
  ) async {
    final api = FakeApiClient(jobs: []);
    final router = await _pumpRouter(tester, saved: {'ui.mode': 'upload'}, api: api);

    final firstRun = find.text('Choose an analysis mode');
    await tester.ensureVisible(firstRun);
    await tester.pumpAndSettle();
    await tester.tap(firstRun);
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, Routes.mode);

    router.go(Routes.home);
    await tester.pumpAndSettle();
    expect(find.text('How do you want to analyze?'), findsOneWidget);
    expect(find.text('Upload and analyze'), findsNothing);

    router.go(Routes.calibrate('vid1'));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, Routes.mode);
    expect(find.text('How do you want to analyze?'), findsOneWidget);
    expect(api.calls, isNot(contains('createJob')));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
