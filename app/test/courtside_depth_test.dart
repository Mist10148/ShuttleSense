import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/live/live_controller.dart';
import 'package:shuttlesense_app/features/live/live_screen.dart';
import 'package:shuttlesense_app/shared/widgets/courtside_tools.dart';
import 'fakes/fake_live.dart';
import 'live_test.dart' show pumpLive, startWithoutCourt, events;

class TestStopwatch extends Stopwatch {
  int milliseconds = 0;
  @override
  int get elapsedMilliseconds => milliseconds;
  @override
  void reset() => milliseconds = 0;
}

void main() {
  testWidgets('lost acknowledgment retries the same command after snapshot recovery', (
    tester,
  ) async {
    final sockets = await pumpLive(
      tester,
      onHello: (hello) => {
        ...startedEvent(resumed: hello['type'] == 'resume'),
        'decision_ack': true,
        'decision_dedup': true,
        'courtside_depth': true,
        'rallies': [],
        'hits': [],
        'line_calls': [],
        'practice_goals': [],
        'decision_log': [],
        'score': {'near': hello['type'] == 'resume' ? 1 : 0, 'far': 0},
      },
    );
    await startWithoutCourt(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    final controller = container.read(liveControllerProvider.notifier);
    controller.award('near');
    final first = sockets.first.sent.last;
    await events(tester);
    expect(find.text('Confirming the referee decision…'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Stop')).onPressed,
      isNull,
    );
    await controller.stop();
    expect(sockets.first.sent.last, first);
    await sockets.first.drop();
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
    await events(tester);
    expect(sockets.length, 2);
    expect(sockets.last.sent.last, first);
    expect(controller.canDecide, isFalse);
    sockets.last.emit({
      'type': 'score',
      'score': {'near': 1, 'far': 0},
      'rallies': [],
      'line_calls': [
        {
          'id': 4,
          'frame': 1,
          'rally_index': 0,
          'time_s': 0.1,
          'call': 'in',
          'landing_xy': [2, 4],
          'margin_cm': 20,
          'confidence': 0.9,
          'uncertain': false,
        },
      ],
      'decision_id': first['decision_id'],
    });
    await events(tester);
    expect(controller.canDecide, isTrue);
    expect(container.read(liveControllerProvider).lineCalls.single.id, 4);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('timer survives rebuild and never starts itself', (tester) async {
    var clock = IntervalState.fromJson({
      'key': 'g1',
      'status': 'ready',
      'remaining_s': 60,
      'duration_s': 60,
    });
    final actions = <String>[];
    final elapsed = TestStopwatch();
    Widget view() => MaterialApp(
      home: Scaffold(
        body: IntervalPanel(interval: clock, onAction: actions.add, elapsedClock: elapsed),
      ),
    );
    await tester.pumpWidget(view());
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('Interval · 60 s'), findsOneWidget);
    await tester.tap(find.text('Start'));
    expect(actions, ['start']);
    clock = IntervalState.fromJson({
      'key': 'g1',
      'status': 'running',
      'remaining_s': 3,
      'duration_s': 60,
    });
    await tester.pumpWidget(view());
    elapsed.milliseconds = 2000;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(view());
    expect(find.text('Interval · 1 s'), findsOneWidget);
    elapsed.milliseconds = 3000;
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Interval complete'), findsOneWidget);
    expect(actions, ['start']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('decision history seeks only to a recorded frame with available video', (
    tester,
  ) async {
    final record = ClipRecord.fromJson({
      'schema_version': '1.6',
      'clip_id': 'test',
      'fps': 30,
      'width': 640,
      'height': 360,
      'num_frames': 30,
      'decision_log': [
        for (final frame in [10, 30])
          {
            'id': frame,
            'kind': 'award',
            'detail': 'Award at frame $frame',
            'game': 1,
            'frame': frame,
            'at': '2026-11-15T00:00:00Z',
            'score': {'near': 1, 'far': 0},
          },
      ],
    });
    final moments = <Moment>[];
    Widget view({required bool available}) => MaterialApp(
      home: Scaffold(
        body: DecisionHistory(record: record, onSeek: available ? moments.add : null),
      ),
    );
    await tester.pumpWidget(view(available: true));
    await tester.tap(find.text('Decision history (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Award at frame 30'));
    await tester.tap(find.text('Award at frame 10'));
    expect(moments.single.frame, 10);
    expect(moments.single.timeS, closeTo(1 / 3, 0.001));
    await tester.pumpWidget(view(available: false));
    await tester.tap(find.text('Award at frame 10'));
    expect(moments, hasLength(1));
  });

  for (final width in [360.0, 800.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('courtside tools at $width / $brightness / 200% text', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final record = ClipRecord.fromJson({
          'schema_version': '1.6',
          'clip_id': 'test',
          'fps': 30,
          'width': 640,
          'height': 360,
          'num_frames': 30,
          'frames': [],
          'hits': [],
          'decision_log': [
            {
              'id': 1,
              'kind': 'award',
              'detail': 'award near service_fault',
              'game': 1,
              'frame': 10,
              'at': '2026-11-15T00:00:00Z',
              'score': {'near': 1, 'far': 0},
              'undone': true,
            },
          ],
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      PracticeGoalCard(
                        goal: const PracticeGoal(
                          text: 'Recover to the centre after each overhead stroke',
                          player: 'near_2',
                        ),
                        onComplete: (_) {},
                        onEdit: () {},
                      ),
                      IntervalPanel(
                        interval: IntervalState.fromJson({
                          'key': 'g1',
                          'status': 'ready',
                          'remaining_s': 120,
                          'duration_s': 120,
                        }),
                        onAction: (_) {},
                      ),
                      DecisionHistory(record: record, onSeek: (_) {}),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Decision history (1)'));
        await tester.tap(find.text('Decision history (1)'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
