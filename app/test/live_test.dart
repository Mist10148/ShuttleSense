import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/config/app_mode.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/live/frame_source.dart';
import 'package:shuttlesense_app/features/live/live_controller.dart';
import 'package:shuttlesense_app/features/live/live_screen.dart';
import 'package:shuttlesense_app/features/live/live_socket.dart';
import 'package:shuttlesense_app/features/mode/mode_screen.dart';
import 'package:shuttlesense_app/features/results/widgets/status_strip.dart';

import 'fakes/fake_api_client.dart';
import 'fakes/fake_live.dart';
import 'helpers.dart';

class DelayedCaptureSource extends FakeFrameSource {
  final pending = Completer<void>();

  @override
  Future<CapturedFrame> capture() async {
    await pending.future;
    return super.capture();
  }
}

/// Pumps the live screen with a fake camera and a fake server; returns the sockets opened.
Future<List<FakeLiveSocket>> pumpLive(
  WidgetTester tester, {
  Size size = phone,
  FakeFrameSource? source,
  bool unreachable = false,
  Map<String, dynamic>? Function(Map<String, dynamic> hello)? onHello,
}) async {
  final sockets = <FakeLiveSocket>[];
  await pumpScreen(
    tester,
    const LiveScreen(),
    size: size,
    prefs: {'ui.mode': 'live'},
    overrides: [
      frameSourceFactoryProvider.overrideWithValue(() => source ?? FakeFrameSource()),
      liveSocketFactoryProvider.overrideWithValue((uri) {
        final s = FakeLiveSocket(
          uri,
          fail: unreachable,
          onHello: onHello ?? (hello) => startedEvent(resumed: hello['type'] == 'resume'),
        );
        sockets.add(s);
        return s;
      }),
    ],
  );
  return sockets;
}

Future<void> startWithoutCourt(WidgetTester tester) async {
  await tester.tap(find.text('Start without court'));
  await events(tester);
  await tester.pump(const Duration(milliseconds: 100));
}

/// Socket events arrive in a microtask; the screen shows them on the next frame.
Future<void> events(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Map<String, dynamic> _hit(int id, int frame) => {
  'id': id,
  'frame': frame,
  'time_s': frame / 15,
  'player': 'near',
  'stroke': 'smash',
  'feedback': <dynamic>[],
};

void main() {
  testWidgets('cancelling during camera sampling cannot start an abandoned session', (
    tester,
  ) async {
    final source = DelayedCaptureSource();
    final sockets = await pumpLive(tester, source: source);
    await tester.tap(find.text('Start without court'));
    await events(tester);
    await tester.tap(find.text('Cancel'));
    await events(tester);
    source.pending.complete();
    await events(tester);
    expect(sockets, isEmpty);
    expect(find.text('Start without court'), findsOneWidget);
    expect(find.textContaining('Camera stopped'), findsNothing);
  });

  testWidgets('changing capture orientation stops the session before sending a distorted frame', (
    tester,
  ) async {
    final source = FakeFrameSource();
    final sockets = await pumpLive(tester, source: source);
    await startWithoutCourt(tester);
    source.width = 720;
    source.height = 1280;
    final sent = sockets.single.frames.length;
    await tester.pump(const Duration(seconds: 1));
    await events(tester);
    expect(sockets.single.frames.length, sent);
    expect(find.textContaining('Camera orientation changed'), findsOneWidget);
    expect(sockets.single.sent.any((message) => message['type'] == 'stop'), isTrue);
  });

  test('frame packets carry index and capture time before the JPEG', () {
    final packet = framePacket(7, 1234.5, Uint8List.fromList([1, 2, 3]));
    final header = ByteData.sublistView(packet, 0, 12);
    expect(header.getUint32(0, Endian.little), 7);
    expect(header.getFloat64(4, Endian.little), 1234.5);
    expect(packet.sublist(12), [1, 2, 3]);
  });

  for (final portrait in [true, false]) {
    testWidgets('fits only the matching capture (portrait: $portrait)', (tester) async {
      final source = FakeFrameSource();
      if (portrait) {
        source.width = 720;
        source.height = 1280;
      }
      final sockets = await pumpLive(tester, source: source);
      await startWithoutCourt(tester);
      final socket = sockets.single;
      expect(socket.frames, isNotEmpty);
      socket.emit(frameEvent(0));
      await events(tester);
      final still = find.byType(Image);
      expect(still, findsOneWidget);
      final size = tester.getSize(still);
      expect(size.aspectRatio, closeTo(source.width / source.height, 0.001));
      socket.emit({...frameEvent(1), 'client_frame': 999});
      await events(tester);
      expect(still, findsNothing);
      expect(find.byKey(const Key('camera-preview')), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await events(tester);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  for (final MapEntry(key: name, value: size) in kSizes.entries) {
    testWidgets('$name: start, stream, see calls and quality, stop and save', (tester) async {
      final sockets = await pumpLive(tester, size: size);
      expect(find.byKey(const Key('camera-preview')), findsOneWidget);
      expect(find.textContaining('not official calls'), findsOneWidget);
      await startWithoutCourt(tester);

      final socket = sockets.single;
      expect(socket.uri.toString(), 'ws://fake:8000/live');
      final start = socket.sent.first;
      expect(start['type'], 'start');
      expect([start['width'], start['height']], [1280, 720]);
      expect(start['corners'], isNull);
      // Frames go out as the camera delivers them.
      await tester.pump(const Duration(milliseconds: 300));
      expect(socket.frames, isNotEmpty);

      for (var i = 0; i < 3; i++) {
        socket.emit(frameEvent(i));
      }
      socket.emit(lineCallEvent());
      socket.emit({
        'type': 'degraded',
        'level': 1,
        'scale': 0.75,
        'reason': 'processing p95 410 ms over the 300 ms budget',
      });
      await events(tester);
      expect(find.text('IN PLAY'), findsOneWidget);
      expect(find.text('Latency 42 ms'), findsOneWidget);
      expect(find.text('Reduced quality'), findsOneWidget);
      expect(find.text('UNCERTAIN'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.ensureVisible(find.text('Confirm OUT'));
      await tester.tap(find.text('Confirm OUT'));
      await events(tester);
      expect(socket.sent.last, {'type': 'override', 'line_call_id': 0, 'call': 'out'});

      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await events(tester);
      await tester.ensureVisible(find.text('Coach'));
      await tester.tap(find.text('Coach'));
      await events(tester);
      expect(find.text('Next rally'), findsOneWidget);
      expect(find.text('Score and stats'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Stop'));
      await events(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(socket.sent.last['type'], 'stop');
      expect(find.textContaining('Session saved to History'), findsOneWidget);
      expect(find.text('Open results'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('orientation change after calibration requires recalibration', (tester) async {
    final source = FakeFrameSource();
    final sockets = await pumpLive(tester, size: laptop, source: source);
    await tester.tap(find.text('Calibrate court'));
    await tester.pumpAndSettle();
    final canvas = tester.getRect(find.byType(Image).first);
    for (final (fx, fy) in [(0.2, 0.9), (0.8, 0.9), (0.7, 0.3), (0.3, 0.3)]) {
      await tester.tapAt(Offset(canvas.left + canvas.width * fx, canvas.top + canvas.height * fy));
      await tester.pump();
    }
    source.width = 720;
    source.height = 1280;
    await tester.tap(find.text('Go live'));
    await events(tester);
    expect(find.textContaining('Recalibrate the court'), findsOneWidget);
    expect(sockets, isEmpty);
  });

  testWidgets('calibrating on a still sends the corners', (tester) async {
    final sockets = await pumpLive(tester, size: laptop);
    await tester.tap(find.text('Calibrate court'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Near left corner'), findsOneWidget);
    final canvas = tester.getRect(find.byType(Image).first);
    for (final (fx, fy) in [(0.2, 0.9), (0.8, 0.9), (0.7, 0.3), (0.3, 0.3)]) {
      await tester.tapAt(Offset(canvas.left + canvas.width * fx, canvas.top + canvas.height * fy));
      await tester.pump();
    }
    await tester.tap(find.text('Go live'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final corners = sockets.single.sent.first['corners'] as List;
    expect(corners, hasLength(4));
    expect((corners.first as List).first, closeTo(1280 * 0.2, 2));
    expect(sockets.single.sent.first['start_score'], isNull);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open results'), findsOneWidget);
  });

  testWidgets('camera permission denied explains what to do', (tester) async {
    await pumpLive(
      tester,
      source: FakeFrameSource(
        error: const CameraUnavailable(
          'Camera access was denied. Allow it.',
          permissionDenied: true,
        ),
      ),
    );
    expect(find.textContaining('Camera access was denied'), findsOneWidget);
    expect(find.byIcon(Icons.no_photography_outlined), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('an unreachable server shows a clear error', (tester) async {
    await pumpLive(tester, unreachable: true);
    await startWithoutCourt(tester);
    expect(find.textContaining('Cannot reach the live server'), findsOneWidget);
  });

  testWidgets('a busy server says why it refused', (tester) async {
    await pumpLive(tester, onHello: (_) => {'type': 'error', 'code': 'busy', 'detail': 'busy'});
    await startWithoutCourt(tester);
    expect(find.textContaining('The server is busy'), findsOneWidget);
  });

  testWidgets('a dropped connection resumes the same session', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    sockets.single.emit(frameEvent(0));
    await events(tester);
    await sockets.single.drop();
    await events(tester);
    expect(find.textContaining('reconnecting'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await events(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(sockets, hasLength(2));
    expect(sockets.last.sent.first, {'type': 'resume', 'session_id': 's1'});
    expect(find.textContaining('reconnecting'), findsNothing);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open results'), findsOneWidget);
  });

  testWidgets('after the camera stops, Try again releases the old camera and socket', (
    tester,
  ) async {
    final cameras = <FakeFrameSource>[];
    final sockets = <FakeLiveSocket>[];
    await pumpScreen(
      tester,
      const LiveScreen(),
      prefs: {'ui.mode': 'live'},
      overrides: [
        frameSourceFactoryProvider.overrideWithValue(() {
          final c = FakeFrameSource();
          cameras.add(c);
          return c;
        }),
        liveSocketFactoryProvider.overrideWithValue((uri) {
          final s = FakeLiveSocket(uri, onHello: (_) => startedEvent());
          sockets.add(s);
          return s;
        }),
      ],
    );
    await startWithoutCourt(tester);
    await tester.pump(const Duration(milliseconds: 200));
    cameras.single.captureError = Exception('camera unplugged');
    await tester.pump(const Duration(milliseconds: 200));
    await events(tester);
    expect(find.textContaining('Camera stopped'), findsOneWidget);
    // The session so far is saved and the connection let go, so the GPU is free again.
    expect(sockets.single.sent.last['type'], 'stop');
    expect(sockets.single.closed, isTrue);

    await tester.tap(find.text('Try again'));
    await events(tester);
    expect(cameras.first.disposed, isTrue);
    expect(cameras, hasLength(2));
    await startWithoutCourt(tester);
    await tester.pump(const Duration(milliseconds: 300));
    // The new session sends straight away, numbering its frames from 0.
    expect(sockets, hasLength(2));
    expect(sockets.last.frames, isNotEmpty);
    expect(ByteData.sublistView(sockets.last.frames.first, 0, 4).getUint32(0, Endian.little), 0);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an override the server cannot find does not end the session', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    sockets.single.emit({'type': 'error', 'code': 'not_found', 'detail': 'no such line call'});
    sockets.single.emit({'type': 'error', 'code': 'internal', 'detail': 'resume to continue'});
    await events(tester);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('no such line call'), findsOneWidget); // said, not swallowed
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('decisions while reconnecting are refused out loud, and Cancel gives up', (
    tester,
  ) async {
    // Every resume is refused as not yet known, so the app keeps reconnecting.
    final sockets = await pumpLive(
      tester,
      onHello: (hello) => hello['type'] == 'resume'
          ? {'type': 'error', 'code': 'not_found', 'detail': 'not yet'}
          : startedEvent(),
    );
    await startWithoutCourt(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    final controller = container.read(liveControllerProvider.notifier);
    await sockets.single.drop();
    await events(tester);
    expect(find.text('Cancel'), findsOneWidget);
    expect(controller.canDecide, isFalse);
    controller.award('near');
    await events(tester);
    expect(find.textContaining('the decision was not sent'), findsOneWidget);
    expect(sockets.single.sent.where((m) => m['type'] == 'award'), isEmpty);
    await tester.tap(find.text('Cancel'));
    await events(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Start without court'), findsOneWidget);
    expect(find.textContaining('saved to History in about a minute'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('started restores the session so far and hits stay in frame order', (tester) async {
    final sockets = await pumpLive(
      tester,
      onHello: (_) => {
        ...startedEvent(),
        'score': {'near': 7, 'far': 3, 'server': 'near', 'service_court': 'left'},
        'rallies': [
          {'index': 0, 'start_frame': 0, 'end_frame': 40, 'winner': 'near'},
        ],
        'line_calls': <dynamic>[],
        'hits': [_hit(0, 10)],
        'rally_state': 'in_play',
        'rally_start_frame': 41,
        'strokes_in_rally': 2,
        'rally_summary': {'index': 0, 'winner': 'near', 'call': 'in'},
      },
    );
    await startWithoutCourt(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    var state = container.read(liveControllerProvider);
    expect((state.score!.near, state.score!.far), (7, 3));
    expect(state.rallies.single.winner, 'near');
    expect(state.lastRally?.winner, 'near');
    expect(state.lastRally?.call, 'in');
    expect((state.rallyState, state.rallyStartFrame, state.strokesInRally), ('in_play', 41, 2));
    sockets.single.emit({'type': 'hit', 'hit': _hit(2, 30)});
    sockets.single.emit({'type': 'hit', 'hit': _hit(1, 20)});
    sockets.single.emit({'type': 'stats', 'processed': 12});
    await events(tester);
    state = container.read(liveControllerProvider);
    expect(state.hits.map((h) => h.frame), [10, 20, 30]);
    expect(find.textContaining('analysed 12'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('referee and coach panels: match setup, award, undo, callout, coaching', (
    tester,
  ) async {
    final sockets = await pumpLive(tester, size: laptop);
    Future<void> pick(String label) async {
      final segment = find.descendant(
        of: find.byWidgetPredicate((w) => w is SegmentedButton),
        matching: find.text(label),
      );
      await tester.ensureVisible(segment);
      await tester.tap(segment);
      await tester.pump();
    }

    await pick('Best of 3');
    await pick('Near');
    await pick('Doubles');
    await startWithoutCourt(tester);
    final socket = sockets.single;
    expect(socket.sent.first['best_of'], 3);
    expect(socket.sent.first['first_server'], 'near');
    expect(socket.sent.first['court'], 'doubles');
    await tester.tap(find.text('Coach'));
    await events(tester);
    expect(find.text('Notes appear here after each rally.'), findsOneWidget);

    socket.emit(frameEvent(0));
    socket.emit({
      'type': 'score',
      'score': {
        'near': 0,
        'far': 0,
        'best_of': 3,
        'server': 'near',
        'service_court': 'right',
        'corrections': [
          {'rally_index': 0, 'winner_before': null, 'winner_after': 'near', 'kind': 'award'},
        ],
      },
      'rallies': <dynamic>[],
    });
    socket.emit({
      'type': 'hit',
      'hit': {..._hit(0, 0), 'speed_kmh': 212.0},
    });
    socket.emit({
      'type': 'coaching',
      'coaching': {
        'session_notes': [
          {
            'id': 'elbow_extension:near',
            'rule': 'elbow_extension',
            'player': 'near',
            'text': 'Near player: Bent hitting arm at contact on 2 of 3 smashes',
            'count': 2,
            'total': 3,
            'severity': 1.0,
          },
        ],
        'top_fixes': ['elbow_extension:near'],
      },
      'rally_summary': {
        'index': 0,
        'duration_s': 6.2,
        'strokes': 5,
        'peak_speed_kmh': 230.0,
        'winner': 'far',
        'call': 'out',
        'faults': [
          {
            'hit_id': 0,
            'player': 'near',
            'stroke': 'smash',
            'rule': 'elbow_extension',
            'tip': 'Extend your hitting arm fully at contact.',
          },
        ],
      },
    });
    await events(tester);
    expect(find.text('Game 1 of 3 · games 0–0'), findsOneWidget);
    expect(find.text('Near serves · right court'), findsOneWidget);
    expect(find.text('Smash by Near · 212 km/h (est.)'), findsOneWidget);
    expect(find.textContaining('Rally 1 · 5 strokes · 6.2 s'), findsOneWidget);
    expect(find.text('Near, Smash: Extend your hitting arm fully at contact.'), findsOneWidget);
    expect(
      find.text('1. Near player: Bent hitting arm at contact on 2 of 3 smashes'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Referee'));
    await tester.tap(find.text('Referee'));
    await events(tester);
    await tester.ensureVisible(find.text('Point Far'));
    await tester.tap(find.text('Point Far'));
    socket.emit({
      'type': 'score',
      'score': {
        'near': 0,
        'far': 1,
        'corrections': [
          {'rally_index': 0, 'winner_before': null, 'winner_after': 'far', 'kind': 'award'},
        ],
      },
      'rallies': <dynamic>[],
    });
    await events(tester);
    await tester.ensureVisible(find.text('Undo'));
    await tester.tap(find.text('Undo'));
    await events(tester);
    expect(socket.sent.where((m) => m['type'] == 'award').single['winner'], 'far');
    expect(socket.sent.where((m) => m['type'] == 'undo'), hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an automatic score or late acknowledgment cannot release a pending decision', (
    tester,
  ) async {
    final sockets = await pumpLive(
      tester,
      onHello: (_) => {...startedEvent(), 'decision_ack': true},
    );
    await startWithoutCourt(tester);
    final socket = sockets.single;
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    final controller = container.read(liveControllerProvider.notifier);
    controller.award('near');
    controller.award('near');
    final id = socket.sent.where((e) => e['type'] == 'award').single['decision_id'];
    final score = {
      'type': 'score',
      'score': {'near': 1, 'far': 0},
      'rallies': [],
    };
    socket.emit(score);
    await events(tester);
    expect(controller.canDecide, isFalse);
    socket.emit({...score, 'decision_id': id});
    await events(tester);
    expect(controller.canDecide, isTrue);
    controller.undo();
    socket.emit({...score, 'decision_id': id});
    await events(tester);
    expect(controller.canDecide, isFalse);
    socket.emit({
      'type': 'error',
      'code': 'not_found',
      'detail': 'Nothing to undo.',
      'decision_id': socket.sent.last['decision_id'],
    });
    await events(tester);
    expect(controller.canDecide, isTrue);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  for (final applied in [true, false]) {
    testWidgets('decision timeout refreshes score without resending (applied: $applied)', (
      tester,
    ) async {
      final sockets = await pumpLive(
        tester,
        onHello: (hello) => {
          ...startedEvent(resumed: hello['type'] == 'resume'),
          'decision_ack': true,
          'score': {'near': hello['type'] == 'resume' && applied ? 1 : 0, 'far': 0},
          'rallies': [],
          'line_calls': [],
          'hits': [],
        },
      );
      await startWithoutCourt(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
      final controller = container.read(liveControllerProvider.notifier);
      controller.award('near');
      await tester.pump(const Duration(seconds: 5));
      expect(controller.canDecide, isFalse);
      expect(sockets.single.closed, isTrue);
      await tester.pump(kReconnectDelays.first);
      await events(tester);
      expect(sockets.last.sent.single['type'], 'resume');
      expect(sockets.first.sent.where((e) => e['type'] == 'award'), hasLength(1));
      expect(container.read(liveControllerProvider).score!.near, applied ? 1 : 0);
      expect(controller.canDecide, isTrue);
      await tester.tap(find.text('Stop'));
      await events(tester);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('a start score also counts without a court', (tester) async {
    final sockets = await pumpLive(tester, size: laptop);
    await tester.tap(find.text('Game already under way'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('7').last);
    await tester.pumpAndSettle();
    await startWithoutCourt(tester);
    expect(sockets.single.sent.first['start_score'], {'near': 7, 'far': 0});
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a resume refused while the server still holds the session is retried', (
    tester,
  ) async {
    var resumes = 0;
    final sockets = await pumpLive(
      tester,
      onHello: (hello) {
        if (hello['type'] != 'resume') return startedEvent();
        resumes++;
        return resumes == 1
            ? {'type': 'error', 'code': 'not_found', 'detail': 'no session to resume'}
            : startedEvent(resumed: true);
      },
    );
    await startWithoutCourt(tester);
    await sockets.single.drop();
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
    await events(tester);
    // The first attempt was refused; the screen keeps saying it is reconnecting.
    expect(find.textContaining('reconnecting'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await events(tester);
    expect(resumes, 2);
    expect(find.textContaining('reconnecting'), findsNothing);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  test('a message that is not a JSON object is dropped, not raised', () {
    expect(decodeEvent('{"type": "frame"}'), [
      {'type': 'frame'},
    ]);
    expect(decodeEvent('1'), isEmpty);
    expect(decodeEvent('not json'), isEmpty);
  });

  testWidgets('frames lost in a drop keep the list indexed by server frame number', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    socket.emit(frameEvent(0));
    socket.emit(frameEvent(4)); // 1-3 were lost
    socket.emit(frameEvent(4)); // repeated after a resume
    await events(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    final state = container.read(liveControllerProvider);
    expect([for (final f in state.frames) f.frame], [0, 1, 2, 3, 4]);
    expect(state.frameIndex, 4);
    expect(state.frames[4].shuttlePos, isNotNull);
    // The rally clock comes from the frame events themselves.
    expect(state.rallyStartFrame, 0);
    socket.emit({...frameEvent(5, state: 'between_rallies'), 'rally_start_frame': null});
    await events(tester);
    expect(container.read(liveControllerProvider).rallyStartFrame, isNull);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  test('the start message announces the rate the camera manages', () {
    expect(liveFps(const Duration(milliseconds: 360), 3), 8.3); // 120 ms per still
    expect(liveFps(const Duration(milliseconds: 30), 3), kLiveTargetFps); // capped
    expect(liveFps(Duration.zero, 3), kLiveTargetFps);
    expect(liveFps(const Duration(seconds: 9), 3), 1.0); // a very slow camera
  });

  testWidgets('a saved session releases the camera and can start a new one', (tester) async {
    final cameras = <FakeFrameSource>[];
    await pumpScreen(
      tester,
      const LiveScreen(),
      prefs: {'ui.mode': 'live'},
      overrides: [
        frameSourceFactoryProvider.overrideWithValue(() {
          final c = FakeFrameSource();
          cameras.add(c);
          return c;
        }),
        liveSocketFactoryProvider.overrideWithValue(
          (uri) => FakeLiveSocket(uri, onHello: (_) => startedEvent()),
        ),
      ],
    );
    await startWithoutCourt(tester);
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Open results'), findsOneWidget);
    expect(cameras.single.disposed, isTrue);
    expect(find.text('New session'), findsOneWidget);
    await tester.tap(find.text('New session'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(cameras, hasLength(2));
    expect(find.text('Start without court'), findsOneWidget);
  });

  test('live mode needs a 1.1 backend', () {
    Health health(String schema) => Health(
      version: '0.1.0',
      schemaVersion: schema,
      device: 'cpu',
      authRequired: false,
      stages: const [],
    );
    expect(health('1.0').supportsLive, isFalse);
    expect(health('1.1').supportsLive, isTrue);
    expect(health('1.4').supportsLive, isTrue);
    expect(health('2.0').supportsLive, isTrue);
  });

  testWidgets('the Analyze tab follows the remembered mode', (tester) async {
    await pumpScreen(
      tester,
      Consumer(
        builder: (context, ref, _) => ref.watch(appModeProvider) == AppMode.live
            ? const Text('live screen')
            : const Scaffold(body: SwitchModeButton()),
      ),
      prefs: {'ui.mode': 'upload'},
    );
    await tester.tap(find.text('Go live'));
    await tester.pumpAndSettle();
    expect(find.text('live screen'), findsOneWidget);
  });

  testWidgets('a game under way starts the live scoreboard from its score', (tester) async {
    final sockets = await pumpLive(tester, size: laptop);
    await tester.tap(find.text('Game already under way'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0').first); // near player's points
    await tester.pumpAndSettle();
    await tester.tap(find.text('7').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calibrate court'));
    await tester.pumpAndSettle();
    final canvas = tester.getRect(find.byType(Image).first);
    for (final (fx, fy) in [(0.2, 0.9), (0.8, 0.9), (0.7, 0.3), (0.3, 0.3)]) {
      await tester.tapAt(Offset(canvas.left + canvas.width * fx, canvas.top + canvas.height * fy));
      await tester.pump();
    }
    await tester.tap(find.text('Go live'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(sockets.single.sent.first['start_score'], {'near': 7, 'far': 0});
    await tester.tap(find.text('Stop'));
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a 1.0 server cannot be switched to live', (tester) async {
    await pumpScreen(
      tester,
      const Scaffold(body: SwitchModeButton()),
      api: FakeApiClient(
        health: const Health(
          version: '0.1.0',
          schemaVersion: '1.0',
          device: 'cpu',
          authRequired: false,
          stages: [],
        ),
      ),
      prefs: {'ui.mode': 'upload'},
    );
    final button = tester.widget<TextButton>(find.byType(TextButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('every speed in the status strip says it is estimated', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: StatusStrip(speedKmh: 182, peakSpeedKmh: 241, strokeCount: 3)),
      ),
    );
    expect(find.textContaining('182 km/h (est.)'), findsOneWidget);
    expect(find.textContaining('241 km/h (est.)'), findsOneWidget);
  });

  test('live state builds a clip record for the shared widgets', () {
    const state = LiveState(sessionId: 's', size: (width: 1280, height: 720));
    final record = state.record;
    expect(record.isLive, isTrue);
    expect(record.width, 1280);
    expect(record.courtCorners, isNull);
  });
}
