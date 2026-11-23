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
