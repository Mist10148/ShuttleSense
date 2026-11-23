import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/features/practice/practice_screen.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

void main() {
  test('practice selection status is parsed separately from running', () {
    expect(JobStatus.parse('needs_selection'), JobStatus.needsSelection);
    expect(JobStatus.needsSelection.isFinished, isFalse);
  });

  testWidgets('practice screen begins with recorded video selection', (tester) async {
    await pumpScreen(tester, const PracticeScreen(), size: laptop);
    expect(find.text('AI Coach'), findsOneWidget);
    expect(find.text('Choose practice video'), findsOneWidget);
    expect(find.textContaining('not verified shuttle contacts'), findsOneWidget);
  });

  testWidgets('running practice offers watch controls and elapsed time', (tester) async {
    final api = _RunningPractice();
    await pumpScreen(
      tester,
      const PracticeScreen(jobId: 'job1'),
      size: laptop,
      api: api,
    );
    expect(find.textContaining('Elapsed:'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop and save'), findsOneWidget);
    await tester.ensureVisible(find.text('Pause'));
    await tester.tap(find.text('Pause'));
    await tester.pump();
    await tester.pump();
    expect(api.actions, ['pause']);
    expect(find.text('Play'), findsOneWidget);
    await tester.tap(find.text('Play'));
    await tester.pump();
    await tester.pump();
    expect(api.actions, ['pause', 'resume']);
    await tester.tap(find.text('Stop and save'));
    await tester.pump();
    await tester.pump();
    expect(api.actions, ['pause', 'resume', 'stop']);
    expect(find.textContaining('Saving session'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('completed analysis offers retry when the coaching report fails', (tester) async {
    await pumpScreen(
      tester,
      const PracticeScreen(jobId: 'job1'),
      size: laptop,
      api: _ReportFails(),
    );
    expect(find.text('Retry coaching report'), findsOneWidget);
    expect(find.textContaining('report unavailable'), findsOneWidget);
  });
}

class _ReportFails extends FakeApiClient {
  @override
  Future<Map<String, dynamic>> practiceStatus(String id) async => {
    'id': id,
    'video_id': 'vid1',
    'status': 'done',
    'practice_setup': {'stroke': 'clear', 'arm': 'right'},
  };

  @override
  Future<Map<String, dynamic>> practiceResult(String id) async =>
      throw Exception('report unavailable');
}

class _RunningPractice extends FakeApiClient {
  final actions = <String>[];
  bool paused = false;
  bool stopping = false;

  @override
  Future<Map<String, dynamic>> practiceStatus(String id) async => {
    'id': id,
    'video_id': 'vid1',
    'status': 'running',
    'progress': 0.2,
    'current_stage': 'practice',
    'started_at': DateTime.now().toUtc().toIso8601String(),
    'control': {'paused': paused, 'stopping': stopping},
  };

  @override
  Future<Map<String, dynamic>> controlPractice(String id, String action) async {
    actions.add(action);
    paused = action == 'pause';
    stopping = action == 'stop';
    return {'paused': paused, 'stopping': stopping};
  }
}
