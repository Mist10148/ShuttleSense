import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/device/screen_awake.dart';
import 'package:shuttlesense_app/core/notifications/job_notifier.dart';
import 'package:shuttlesense_app/core/router/app_router.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/repositories/analysis_repository.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

void main() {
  testWidgets('an unknown path shows the 404 page, and Go to Home leaves it', (tester) async {
    setSize(tester, laptop);
    SharedPreferences.setMockInitialValues({'server.baseUrl': 'http://fake:8000'});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        apiClientProvider.overrideWithValue(FakeApiClient()),
        jobNotifierProvider.overrideWithValue(const NoopJobNotifier()),
        screenAwakeProvider.overrideWithValue(FakeScreenAwake()),
      ],
    );
    addTearDown(container.dispose);
    final router = container.read(routerProvider);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    router.go('/no/such/page');
    await tester.pumpAndSettle();
    expect(find.text('Page not found'), findsWidgets);
    expect(find.textContaining('/no/such/page'), findsOneWidget);

    await tester.tap(find.text('Go to Home'));
    await tester.pumpAndSettle();
    expect(find.text('Page not found'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
