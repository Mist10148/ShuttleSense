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
  test('frame packets carry index and capture time before the JPEG', () {
    final packet = framePacket(7, 1234.5, Uint8List.fromList([1, 2, 3]));
    final header = ByteData.sublistView(packet, 0, 12);
    expect(header.getUint32(0, Endian.little), 7);
    expect(header.getFloat64(4, Endian.little), 1234.5);
    expect(packet.sublist(12), [1, 2, 3]);
  });

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

      await tester.tap(find.text('Stop'));
      await events(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(socket.sent.last['type'], 'stop');
      expect(find.textContaining('Session saved to History'), findsOneWidget);
      expect(find.text('Open results'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });
  }

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
        error: CameraUnavailable('Camera access was denied. Allow it.', permissionDenied: true),
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
      },
    );
    await startWithoutCourt(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    var state = container.read(liveControllerProvider);
    expect((state.score!.near, state.score!.far), (7, 3));
    expect(state.rallies.single.winner, 'near');
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
