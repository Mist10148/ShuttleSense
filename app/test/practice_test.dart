import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/features/practice/practice_screen.dart';

import 'fakes/fake_api_client.dart';
import 'fakes/fake_file_picker.dart';
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

  testWidgets('practice Watch pauses and saves without sending extra frames', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    final socket = _PracticeSocket();
    addTearDown(socket.incoming.close);
    await pumpScreen(
      tester,
      PracticeScreen(channelFactory: (_) => socket),
      size: laptop,
      api: _PracticeWatchApi(),
    );
    await tester.tap(find.text('Choose practice video'));
    await tester.pumpAndSettle();
    final image = find.byType(Image).first;
    await tester.ensureVisible(image);
    await tester.pump();
    await tester.tapAt(tester.getTopLeft(image) + const Offset(30, 30));
    await tester.ensureVisible(find.text('Find court automatically'));
    await tester.tap(find.text('Find court automatically'));
    await tester.pump();
    await tester.ensureVisible(find.text('Confirm and analyze'));
    await tester.pump();
    await tester.tap(find.text('Confirm and analyze'));
    await tester.pump();
    expect(socket.outgoing.messages.first['mode'], 'practice');
    expect(socket.outgoing.messages.first['corners'], hasLength(4));
    socket.send({'type': 'started', 'fps': 25, 'frames': 10, 'width': 1280, 'height': 720});
    await tester.pump();
    expect(socket.outgoing.messages.where((m) => m['type'] == 'next'), hasLength(1));
    await tester.ensureVisible(find.text('Pause'));
    await tester.tap(find.text('Pause'));
    await tester.pump();
    socket.send({
      'type': 'video_frame',
      'index': 0,
      'jpeg':
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+nmXQAAAAASUVORK5CYII=',
      'events': [
        {
          'type': 'frame',
          'frame': 0,
          'players': {'near': null},
          'selected_visible': false,
        },
      ],
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Selected player uncertain'), findsOneWidget);
    expect(socket.outgoing.messages.where((m) => m['type'] == 'next'), hasLength(1));
    await tester.tap(find.text('Play'));
    await tester.pump();
    expect(socket.outgoing.messages.where((m) => m['type'] == 'next'), hasLength(2));
    await tester.tap(find.text('Stop and save'));
    await tester.pump();
    expect(socket.outgoing.messages.last['type'], 'stop');
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

class _PracticeWatchApi extends FakeApiClient {
  @override
  Future<Health> health() async => const Health(
    version: '1',
    schemaVersion: '1',
    device: 'cpu',
    authRequired: false,
    stages: [],
    practiceVideo: true,
    practiceWatch: true,
    practiceCourtWatch: true,
  );
  @override
  Future<List<({double x, double y})>?> suggestCourtCorners(String videoId, int frame) async => [
    (x: 250.0, y: 600.0),
    (x: 1030.0, y: 600.0),
    (x: 850.0, y: 100.0),
    (x: 430.0, y: 100.0),
  ];
  @override
  Future<Map<String, dynamic>> practicePlayers(String videoId, int frame) async => {
    'candidates': [
      {
        'bbox': [0, 0, 700, 650],
      },
    ],
  };
}

class _PracticeSink extends Fake implements WebSocketSink {
  final messages = <Map<String, dynamic>>[];
  @override
  void add(dynamic data) => messages.add(jsonDecode(data as String) as Map<String, dynamic>);
  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
}

class _PracticeSocket extends Fake implements WebSocketChannel {
  final incoming = StreamController<dynamic>.broadcast(sync: true);
  final outgoing = _PracticeSink();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  WebSocketSink get sink => outgoing;
  @override
  Future<void> get ready async {}
  void send(Map<String, dynamic> message) => incoming.add(jsonEncode(message));
}
