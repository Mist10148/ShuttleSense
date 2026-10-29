import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/features/history/history_screen.dart';
import 'package:shuttlesense_app/features/processing/processing_screen.dart';
import 'package:shuttlesense_app/features/settings/settings_screen.dart';
import 'package:shuttlesense_app/shared/widgets/offline_banner.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

/// Every screen that does not need a video player renders at all three sizes with the fake
/// API and no layout overflow (T4.12).
void main() {
  for (final MapEntry(key: name, value: size) in kSizes.entries) {
    group(name, () {
      testWidgets('history', (tester) async {
        await pumpScreen(tester, const HistoryScreen(), size: size);
        expect(find.textContaining('job1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('processing (failed job)', (tester) async {
        final api = FakeApiClient(
          jobs: [Job.fromJson(jobJson(status: 'failed', progress: 0.3, error: 'boom'))],
        );
        await pumpScreen(
          tester,
          const ProcessingScreen(jobId: 'job1'),
          size: size,
          api: api,
        );
        expect(find.text('boom'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('settings', (tester) async {
        await pumpScreen(tester, const SettingsScreen(), size: size);
        expect(find.textContaining('0.1.0'), findsWidgets);
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('theme mode is chosen in settings and remembered', (tester) async {
    await pumpScreen(tester, const SettingsScreen());
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ui.themeMode'), 'dark');
  });

  testWidgets('offline banner appears when the server does not answer', (tester) async {
    final api = FakeApiClient()..failWith = ApiException('Cannot reach server at http://fake');
    await pumpScreen(tester, const OfflineBanner(child: Text('content')), api: api);
    expect(find.textContaining('Server unreachable'), findsOneWidget);
    api.failWith = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Server unreachable'), findsNothing);
  });

  testWidgets('fake API errors show a retry message', (tester) async {
    final api = FakeApiClient()..failWith = ApiException('Cannot reach server at http://fake');
    await pumpScreen(tester, const HistoryScreen(), api: api);
    expect(find.text('Could not load jobs'), findsOneWidget);
  });
}
