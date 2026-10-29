import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/data/repositories/analysis_repository.dart';
import 'package:shuttlesense_app/features/processing/processing_screen.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

/// Serves [job] through jobProvider without the polling loop (no pending timers in tests).
Override fixedJob(Job job) => jobProvider.overrideWith((ref, _) => Stream.value(job));

void main() {
  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 42)), '42 s');
    expect(formatDuration(const Duration(seconds: 65)), '1 min 05 s');
  });

  testWidgets('running job shows the stage, elapsed time and cancel asks first', (tester) async {
    final api = FakeApiClient();
    final running = Job.fromJson(jobJson(status: 'running', progress: 0.5));
    await pumpScreen(
      tester,
      const ProcessingScreen(jobId: 'job1'),
      api: api,
      overrides: [fixedJob(running)],
    );
    expect(find.text('Running: Players and pose'), findsOneWidget);
    expect(find.textContaining('Elapsed'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel processing?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(api.calls, isNot(contains('deleteJob job1')));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel job'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('deleteJob job1'));
  });

  testWidgets('failed job can be retried with the same options', (tester) async {
    final api = FakeApiClient(
      jobs: [Job.fromJson(jobJson(status: 'failed', error: 'stage pose failed'))],
    );
    final visited = await pumpScreen(tester, const ProcessingScreen(jobId: 'job1'), api: api);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('createJob vid1 trail,boxes'));
    expect(visited, ['/jobs/job2']);
  });

  testWidgets('polling backs off on errors before giving up', (tester) async {
    final api = FakeApiClient()..failWith = ApiException('Cannot reach server');
    await pumpScreen(tester, const ProcessingScreen(jobId: 'job1'), api: api, settle: false);
    await tester.pump();
    expect(find.text('Lost connection to server'), findsNothing);
    for (final wait in kPollBackoff) {
      await tester.pump(wait);
    }
    await tester.pump();
    expect(find.text('Lost connection to server'), findsOneWidget);
    expect(api.calls.where((c) => c == 'getJob job1'), hasLength(kPollBackoff.length + 1));
  });
}
