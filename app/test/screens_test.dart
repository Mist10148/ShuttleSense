import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/features/history/history_screen.dart';
import 'package:shuttlesense_app/features/processing/processing_screen.dart';
import 'package:shuttlesense_app/features/settings/settings_screen.dart';

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

  testWidgets('fake API errors show a retry message', (tester) async {
    final api = FakeApiClient()..failWith = ApiException('Cannot reach server at http://fake');
    await pumpScreen(tester, const HistoryScreen(), api: api);
    expect(find.text('Could not load jobs'), findsOneWidget);
  });
}
