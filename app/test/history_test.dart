import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/features/history/history_screen.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

void main() {
  testWidgets('shows the video filename', (tester) async {
    await pumpScreen(tester, const HistoryScreen());
    expect(find.text('rally01.mp4'), findsOneWidget);
  });

  testWidgets('delete asks first, then deletes the job only', (tester) async {
    final api = FakeApiClient();
    await pumpScreen(tester, const HistoryScreen(), api: api);
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete analysis?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.calls.where((c) => c.startsWith('delete')), isEmpty);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('deleteJob job1'));
    expect(find.text('No analyses on this server yet'), findsOneWidget);
  });

  testWidgets('swipe to delete can also delete the video', (tester) async {
    final api = FakeApiClient();
    await pumpScreen(tester, const HistoryScreen(), api: api);
    await tester.drag(find.text('rally01.mp4'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Also delete the uploaded video'));
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('deleteVideo vid1'));
  });

  testWidgets('a swipe whose delete fails keeps the job and says why', (tester) async {
    final api = _DeleteFails();
    await pumpScreen(tester, const HistoryScreen(), api: api);
    await tester.drag(find.text('rally01.mp4'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not delete'), findsOneWidget);
    expect(find.text('rally01.mp4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a finished job opens its results', (tester) async {
    final visited = await pumpScreen(tester, const HistoryScreen());
    await tester.tap(find.text('rally01.mp4'));
    await tester.pumpAndSettle();
    expect(visited, ['/jobs/job1/results']);
  });
}

class _DeleteFails extends FakeApiClient {
  @override
  Future<void> deleteJob(String jobId) async {
    calls.add('deleteJob $jobId');
    throw ApiException('job is busy', statusCode: 409);
  }
}
