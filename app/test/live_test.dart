import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/device/screen_awake.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/features/live/frame_source.dart';
import 'package:shuttlesense_app/features/live/live_controller.dart';
import 'package:shuttlesense_app/features/live/live_screen.dart';
import 'package:shuttlesense_app/features/live/live_socket.dart';
import 'package:shuttlesense_app/features/mode/mode_screen.dart';
import 'package:shuttlesense_app/features/results/widgets/court_minimap.dart';
import 'package:shuttlesense_app/features/results/widgets/status_strip.dart';

import 'fakes/fake_api_client.dart';
import 'fakes/fake_live.dart';
import 'helpers.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';

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
  FakeApiClient? api,
  bool unreachable = false,
  Brightness brightness = Brightness.light,
  TextScaler textScaler = TextScaler.noScaling,
  Map<String, dynamic>? Function(Map<String, dynamic> hello)? onHello,
}) async {
  final sockets = <FakeLiveSocket>[];
  await pumpScreen(
    tester,
    const LiveScreen(),
    size: size,
    api: api,
    brightness: brightness,
    textScaler: textScaler,
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

/// Stop, confirming the save when the session has rallies or decisions (T12.6).
Future<void> tapStop(WidgetTester tester) async {
  await tester.tap(find.text('Stop'));
  await tester.pump();
  final confirm = find.widgetWithText(FilledButton, 'Stop and save');
  if (confirm.evaluate().isNotEmpty) {
    await tester.tap(confirm.last);
    await tester.pump();
  }
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
    testWidgets('fits the last matching capture (portrait: $portrait)', (tester) async {
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
      final matched = tester.widget<Image>(still).key;
      socket.emit({...frameEvent(1), 'client_frame': 999});
      await events(tester);
      expect(tester.widget<Image>(still).key, matched);
      expect(tester.getSize(still).aspectRatio, closeTo(source.width / source.height, 0.001));
      expect(find.textContaining('Waiting for a fresh analysis overlay'), findsOneWidget);
      await tapStop(tester);
      await events(tester);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  for (final MapEntry(key: name, value: size) in kSizes.entries) {
    for (final brightness in Brightness.values) {
      testWidgets('$name ${brightness.name}: start, review calls, coach and save', (tester) async {
        final sockets = await pumpLive(tester, size: size, brightness: brightness);
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

        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await events(tester);
        for (var i = 0; i < 3; i++) {
          socket.emit(frameEvent(i));
        }
        socket.emit(lineCallEvent());
        socket.emit(lineCallEvent(id: 1, call: 'in'));
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
        expect(find.text('2 calls awaiting review'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.text('Confirm OUT'));
        await tester.tap(find.text('Confirm OUT'));
        await events(tester);
        expect(socket.sent.last, {'type': 'override', 'line_call_id': 0, 'call': 'out'});
        socket.emit(lineCallEvent(override: 'out'));
        socket.emit({
          'type': 'score',
          'score': {'near': 0, 'far': 0},
          'rallies': [],
        });
        await events(tester);
        expect(find.text('1 call awaiting review'), findsOneWidget);

        await tester.ensureVisible(find.text('Confirm IN'));
        await tester.tap(find.text('Confirm IN'));
        await events(tester);
        expect(socket.sent.last, {'type': 'override', 'line_call_id': 1, 'call': 'in'});
        socket.emit(lineCallEvent(id: 1, call: 'in', override: 'in'));
        socket.emit({
          'type': 'score',
          'score': {'near': 0, 'far': 0},
          'rallies': [],
        });
        await events(tester);
        await tester.ensureVisible(find.text('Coach'));
        await tester.tap(find.text('Coach'));
        await events(tester);
        expect(find.text('Next rally'), findsOneWidget);
        expect(find.text('Score and stats'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tapStop(tester);
        await events(tester);
        await tester.pump(const Duration(milliseconds: 100));
        expect(socket.sent.last['type'], 'stop');
        expect(find.textContaining('Session saved to History'), findsOneWidget);
        expect(find.text('Open results'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }

  testWidgets('a skipped frame keeps the last matched camera overlay', (tester) async {
    final sockets = await pumpLive(tester, size: laptop);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    final controller = container.read(liveControllerProvider.notifier);
    await tester.pump(const Duration(milliseconds: 100));
    expect(socket.frames, isNotEmpty);
    socket.emit(frameEvent(0));
    await events(tester);
    final image = controller.analyzedImage;
    expect(image, isNotNull);
    expect(controller.waitingForAnalysis, isFalse);

    socket.emit({...frameEvent(1), 'skipped': true, 'players': <String, dynamic>{}});
    await events(tester);
    expect(controller.analyzedImage, same(image));
    expect(container.read(liveControllerProvider).players.keys, ['near']);
    expect(controller.waitingForAnalysis, isTrue);
    for (var i = 0; i < 10 && socket.frames.length < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final packet = socket.frames.last;
    final index = ByteData.sublistView(packet).getUint32(0, Endian.little);
    expect(index, greaterThan(1));
    socket.emit({...frameEvent(index), 'players': <String, dynamic>{}});
    await events(tester);
    expect(controller.analyzedImage, isNot(same(image)));
    expect(container.read(liveControllerProvider).players, isEmpty);
    expect(controller.waitingForAnalysis, isFalse);
    await tapStop(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a held display box is marked without a measured player', (tester) async {
    final sockets = await pumpLive(tester, size: laptop);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    await tester.pump(const Duration(milliseconds: 100));
    socket.emit({
      ...frameEvent(0),
      'players': <String, dynamic>{},
      'display_players': {
        'near': {
          'bbox': [10, 20, 30, 40],
          'held': true,
        },
      },
    });
    await events(tester);
    final player = container.read(liveControllerProvider).players['near'];
    expect(player?.held, isTrue);
    expect(player?.keypoints, isEmpty);
    await tapStop(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('review a later call and advance only after its score acknowledgment', (
    tester,
  ) async {
    final sockets = await pumpLive(tester, size: laptop);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    socket.emit(lineCallEvent(id: 3, rally: 2, frame: 120, call: 'in'));
    socket.emit(lineCallEvent(id: 2, rally: 1, frame: 60));
    await events(tester);

    final queue = find.byKey(const Key('live-review-queue'));
    int? highlighted() => tester.widget<CourtMinimap>(find.byType(CourtMinimap)).reviewCall?.id;
    expect(tester.widget<DropdownButton<int>>(queue).value, 2);
    expect(highlighted(), 2);
    await tester.tap(queue);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rally 3 \u00b7 0:08.0').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Confirm IN'));
    await tester.tap(find.text('Confirm IN'));
    expect(socket.sent.last, {'type': 'override', 'line_call_id': 3, 'call': 'in'});
    socket.emit({'type': 'error', 'code': 'not_found', 'detail': 'Try that call again'});
    await events(tester);
    expect(tester.widget<DropdownButton<int>>(queue).value, 3);
    await tester.tap(find.text('Confirm IN'));
    socket.emit(lineCallEvent(id: 3, rally: 2, frame: 120, call: 'in', override: 'in'));
    await events(tester);
    expect(find.text('IN'), findsOneWidget);
    expect(highlighted(), 3);
    expect(find.text('Confirm OUT'), findsNothing);

    socket.emit({
      'type': 'score',
      'score': {'near': 1, 'far': 0},
      'rallies': [],
    });
    await events(tester);
    expect(find.text('Rally 2 \u00b7 0:04.0'), findsOneWidget);
    expect(highlighted(), 2);
    expect(find.text('Confirm OUT'), findsOneWidget);
    await tapStop(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a lost review acknowledgment refreshes the queue and score together', (
    tester,
  ) async {
    final first = lineCallEvent(id: 1, rally: 0, frame: 30);
    final second = lineCallEvent(id: 2, rally: 1, frame: 60, call: 'in');
    final sockets = await pumpLive(
      tester,
      size: laptop,
      onHello: (hello) => hello['type'] == 'resume'
          ? {
              ...startedEvent(resumed: true, frames: 90),
              'decision_ack': true,
              'score': {'near': 1, 'far': 0},
              'rallies': [],
              'hits': [],
              'line_calls': [
                first['line_call'],
                lineCallEvent(id: 2, rally: 1, frame: 60, call: 'in', override: 'in')['line_call'],
              ],
            }
          : {...startedEvent(), 'decision_ack': true},
    );
    await startWithoutCourt(tester);
    final socket = sockets.single;
    socket.emit(first);
    socket.emit(second);
    await events(tester);

    await tester.tap(find.byKey(const Key('live-review-queue')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rally 2 \u00b7 0:04.0').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm IN'));
    expect(socket.sent.last['line_call_id'], 2);
    await tester.pump(const Duration(seconds: 5));
    await events(tester);
    expect(socket.closed, isTrue);
    expect(find.text('Reconnecting and refreshing the score\u2026'), findsOneWidget);

    await tester.pump(kReconnectDelays.first);
    await events(tester);
    expect(sockets.last.sent.single['type'], 'resume');
    expect(find.text('1 call awaiting review'), findsOneWidget);
    expect(find.text('Rally 1 \u00b7 0:02.0'), findsOneWidget);
    expect(find.text('Confirm OUT'), findsOneWidget);
    expect(find.text('Confirm IN'), findsNothing);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    final state = container.read(liveControllerProvider);
    expect(state.score!.near, 1);
    expect(state.lineCalls.singleWhere((call) => call.id == 2).reviewed, isTrue);
    await tapStop(tester);
    await tester.pump(const Duration(seconds: 1));
  });

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
    await tapStop(tester);
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

  testWidgets('a socket closed before started fails at once, not after the start timeout', (
    tester,
  ) async {
    final sockets = await pumpLive(tester, onHello: (_) => null);
    await startWithoutCourt(tester);
    expect(find.textContaining('closed the connection'), findsNothing);
    await sockets.single.drop();
    await events(tester);
    expect(find.textContaining('The live server closed the connection'), findsOneWidget);
  });

  testWidgets('a refused start keeps the start score for Try again', (tester) async {
    final sockets = await pumpLive(
      tester,
      size: laptop,
      onHello: (_) => {'type': 'error', 'code': 'busy', 'detail': 'busy'},
    );
    await tester.tap(find.text('Game already under way'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('7').last);
    await tester.pumpAndSettle();
    await startWithoutCourt(tester);
    expect(sockets.single.sent.first['start_score'], {'near': 7, 'far': 0});
    expect(find.textContaining('The server is busy'), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    expect(container.read(liveStartScoreProvider), (near: 7, far: 0));
  });

  testWidgets('a dropped connection resumes the same session', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    sockets.single.emit(frameEvent(0));
    await events(tester);
    await sockets.single.drop();
    await events(tester);
    expect(find.text('Reconnecting and refreshing the score\u2026'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await events(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(sockets, hasLength(2));
    expect(sockets.last.sent.first, {'type': 'resume', 'session_id': 's1'});
    expect(find.text('Reconnecting and refreshing the score\u2026'), findsNothing);
    await tapStop(tester);
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
    final stopped = find.textContaining('Camera stopped');
    // The capture schedule uses a wall-clock Stopwatch while pump advances Flutter's
    // fake clock. Wait for the next capture instead of assuming it falls in one pump.
    for (var i = 0; i < 10 && stopped.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(stopped, findsOneWidget);
    // The session so far is saved and the connection let go, so the GPU is free again.
    expect(sockets.single.sent.last['type'], 'stop');
    expect(sockets.single.closed, isTrue);
    expect(cameras.single.disposed, isTrue);

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
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an award refused during a rally does not end the session', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    sockets.single.emit({'type': 'error', 'code': 'rally_in_play', 'detail': 'wait'});
    await events(tester);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Wait until the rally has ended, then award the point'), findsOneWidget);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a double tap on Start opens one session (T12.5)', (tester) async {
    final sockets = await pumpLive(tester);
    // Both taps land before the screen rebuilds without the button.
    await tester.tap(find.text('Start without court'));
    await tester.tap(find.text('Start without court'), warnIfMissed: false);
    await events(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(sockets, hasLength(1));
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('match_over and an unknown error code do not end the session (T12.5)', (
    tester,
  ) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    sockets.single.emit({'type': 'error', 'code': 'match_over', 'detail': 'won'});
    await events(tester);
    expect(find.text('The match is already won: Undo first to change the result'), findsOneWidget);
    sockets.single.emit({'type': 'error', 'code': 'from_a_newer_server', 'detail': 'heads up'});
    await events(tester);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('heads up'), findsOneWidget);
    await tapStop(tester);
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
    await tapStop(tester);
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
        ...startedEvent(frames: 44),
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
    expect(state.frameIndex, 43);
    sockets.single.emit({'type': 'hit', 'hit': _hit(2, 30)});
    sockets.single.emit({'type': 'hit', 'hit': _hit(1, 20)});
    sockets.single.emit({'type': 'stats', 'processed': 12});
    await events(tester);
    state = container.read(liveControllerProvider);
    expect(state.hits.map((h) => h.frame), [10, 20, 30]);
    expect(find.textContaining('analysed 12'), findsOneWidget);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('coach panel in doubles: side filter keeps partner notes and cues name the partner', (
    tester,
  ) async {
    final sockets = await pumpLive(tester, size: laptop);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    await tester.tap(find.text('Coach'));
    await events(tester);
    Map<String, dynamic> note(String id, String player, String text, double severity) => {
      'id': id,
      'rule': id.split(':').first,
      'player': player,
      'text': text,
      'count': 2,
      'total': 3,
      'severity': severity,
    };
    socket.emit(frameEvent(0));
    socket.emit({
      'type': 'hit',
      'hit': {..._hit(0, 0), 'hitter': 'near_2'},
    });
    socket.emit({
      'type': 'coaching',
      'coaching': {
        'session_notes': [
          note('elbow_extension:near_2', 'near_2', 'Near player 2: Bent hitting arm', 1.0),
          note('contact_height:near_1', 'near_1', 'Near player 1: Low contact point', 1.0),
          note('recovery:far_1', 'far_1', 'Far player 1: Slow recovery', 1.0),
          note('formation:near', 'near', 'Near pair: Mostly side by side', 0.0),
        ],
        'top_fixes': ['elbow_extension:near_2', 'contact_height:near_1', 'recovery:far_1'],
      },
      'rally_summary': {
        'index': 0,
        'strokes': 3,
        'faults': [
          {
            'hit_id': 0,
            'player': 'near',
            'stroke': 'smash',
            'rule': 'elbow_extension',
            'tip': 'Extend your hitting arm fully at contact.',
          },
          {
            'hit_id': 9,
            'player': 'far',
            'hitter': 'far_1',
            'stroke': 'clear',
            'rule': 'recovery',
            'tip': 'Recover to base sooner.',
          },
        ],
      },
    });
    await events(tester);
    // The partner comes from the fault's hit when the event carries only the side.
    expect(find.text('Near 2, Smash: Extend your hitting arm fully at contact.'), findsOneWidget);

    final nearFilter = find.widgetWithText(ChoiceChip, 'Near');
    await tester.ensureVisible(nearFilter);
    await tester.tap(nearFilter);
    await events(tester);
    expect(find.text('1. Near player 1: Low contact point'), findsOneWidget);
    expect(find.text('2. Near player 2: Bent hitting arm'), findsOneWidget);
    expect(find.textContaining('Slow recovery'), findsNothing);
    expect(find.textContaining('side by side'), findsNothing);

    final farFilter = find.widgetWithText(ChoiceChip, 'Far');
    await tester.ensureVisible(farFilter);
    await tester.tap(farFilter);
    await events(tester);
    expect(find.text('1. Far player 1: Slow recovery'), findsOneWidget);
    expect(find.textContaining('Bent hitting arm'), findsNothing);
    expect(find.text('Far 1, Clear: Recover to base sooner.'), findsOneWidget);

    await tester.ensureVisible(find.text('Stop'));
    await tapStop(tester);
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
    final farFilter = find.widgetWithText(ChoiceChip, 'Far');
    await tester.ensureVisible(farFilter);
    await tester.tap(farFilter);
    await events(tester);
    expect(find.text('Waiting for enough footage to suggest a cue for Far.'), findsOneWidget);
    expect(find.textContaining('Bent hitting arm'), findsNothing);

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
    socket.emit({
      'type': 'score',
      'score': {'near': 0, 'far': 0},
      'rallies': [],
    });
    await events(tester);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('recent coach rallies stay filtered after switching roles', (tester) async {
    final sockets = await pumpLive(tester, size: tablet);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    for (var i = 0; i < 4; i++) {
      socket.emit({
        'type': 'rally',
        'state': 'between_rallies',
        'rally': {'index': i, 'start_frame': i * 30, 'end_frame': i * 30 + 20, 'stroke_count': 2},
      });
    }
    for (final player in ['near', 'far']) {
      socket.emit({
        'type': 'hit',
        'hit': {
          ..._hit(player == 'near' ? 1 : 2, 68),
          'player': player,
          'feedback': [
            {'rule': 'extension', 'passed': false, 'tip': 'Earlier cue for $player'},
          ],
        },
      });
    }
    await events(tester);
    await tester.tap(find.text('Coach'));
    await events(tester);

    final far = find.widgetWithText(ChoiceChip, 'Far');
    await tester.ensureVisible(far);
    await tester.tap(far);
    await events(tester);
    await tester.ensureVisible(find.text('Referee'));
    await tester.tap(find.text('Referee'));
    await events(tester);
    await tester.tap(find.text('Coach'));
    await events(tester);
    expect(tester.widget<ChoiceChip>(far).selected, isTrue);
    expect(find.text('Far, Smash: Earlier cue for far'), findsNothing);

    final recent = find.text('Recent completed rallies');
    await tester.ensureVisible(recent);
    await tester.tap(recent);
    await tester.pumpAndSettle();
    expect(find.text('Rally 4 \u00b7 2 strokes'), findsOneWidget);
    expect(find.text('Rally 3 \u00b7 2 strokes'), findsOneWidget);
    expect(find.text('Rally 2 \u00b7 2 strokes'), findsOneWidget);
    expect(find.text('Rally 1 \u00b7 2 strokes'), findsNothing);
    expect(find.text('Far, Smash: Earlier cue for far'), findsOneWidget);
    expect(find.text('Near, Smash: Earlier cue for near'), findsNothing);
    expect(find.text('Point Far'), findsNothing);
    final pin = find.text('Pin cue');
    await tester.ensureVisible(pin);
    await tester.tap(pin);
    await events(tester);
    final pinned = find.text('Pinned practice cue · Rally 3');
    expect(pinned, findsOneWidget);
    final near = find.widgetWithText(ChoiceChip, 'Near');
    await tester.ensureVisible(near);
    await tester.tap(near);
    await events(tester);
    expect(pinned, findsNothing);
    await tester.tap(far);
    await events(tester);
    expect(pinned, findsOneWidget);
    await tester.ensureVisible(find.text('Referee'));
    await tester.tap(find.text('Referee'));
    await events(tester);
    await socket.drop();
    await events(tester);
    await tester.pump(kReconnectDelays.first);
    await events(tester);
    expect(sockets.last.sent.first['type'], 'resume');
    await tester.tap(find.text('Coach'));
    await events(tester);
    expect(pinned, findsOneWidget);
    final clear = find.text('Clear pin');
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await events(tester);
    expect(pinned, findsNothing);

    await tapStop(tester);
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
    await tapStop(tester);
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
      await tapStop(tester);
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
    await tapStop(tester);
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
    expect(find.text('Reconnecting and refreshing the score\u2026'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    await tester.pump(const Duration(seconds: 2));
    await events(tester);
    expect(resumes, 2);
    expect(find.text('Reconnecting and refreshing the score\u2026'), findsNothing);
    await tapStop(tester);
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
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  test('the start message announces the rate the camera manages', () {
    expect(liveFps(const Duration(milliseconds: 360), 3), 8.3); // 120 ms per still
    expect(liveFps(const Duration(milliseconds: 30), 3), kLiveTargetFps); // capped
    expect(liveFps(Duration.zero, 3), kLiveTargetFps);
    expect(liveFps(const Duration(seconds: 9), 3), 1.0); // a very slow camera
  });

  for (final failure in ['send', 'disconnect', 'timeout']) {
    testWidgets('stopping releases the camera on $failure', (tester) async {
      final camera = FakeFrameSource();
      final sockets = await pumpLive(tester, source: camera);
      await startWithoutCourt(tester);
      final socket = sockets.single..replyToStop = false;
      if (failure == 'send') socket.stopError = StateError('socket closed');

      await tapStop(tester);
      await events(tester);
      expect(camera.disposed, isTrue);
      if (failure == 'disconnect') await socket.drop();
      if (failure == 'timeout') await tester.pump(const Duration(seconds: 91));
      await events(tester);

      expect(find.textContaining('did not confirm the save'), findsOneWidget);
      expect(socket.closed, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  for (final outcome in ['present', 'absent', 'offline then present']) {
    testWidgets('lost save reply: $outcome', (tester) async {
      final api = FakeApiClient(
        jobs: [
          if (outcome != 'absent')
            Job.fromJson({...jobJson(id: 'reserved', status: 'running'), 'mode': 'live'}),
        ],
      );
      final sockets = await pumpLive(
        tester,
        api: api,
        onHello: (_) => {...startedEvent(), 'job_id': 'reserved'},
      );
      await startWithoutCourt(tester);
      final socket = sockets.single..replyToStop = false;
      if (outcome == 'offline then present') api.failWith = ApiException('offline');
      await tapStop(tester);
      await events(tester);
      await socket.drop();
      await events(tester);
      expect(api.calls.where((call) => call == 'getJob reserved'), hasLength(1));
      api.failWith = null;
      await tester.pump(const Duration(milliseconds: 500));
      await events(tester);
      await tester.pump(const Duration(seconds: 1));
      await events(tester);

      if (outcome == 'absent') {
        expect(api.calls.where((call) => call == 'getJob reserved'), hasLength(3));
        expect(find.text('Open History'), findsOneWidget);
      } else {
        expect(find.text('Open results'), findsOneWidget);
      }
    });
  }

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
    await tapStop(tester);
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

  testWidgets('Change mode returns to the mode chooser', (tester) async {
    final visited = await pumpScreen(tester, const Scaffold(body: ChangeModeButton()));
    await tester.tap(find.text('Change mode'));
    await tester.pumpAndSettle();
    expect(visited, ['/mode']);
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
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('every speed in the status strip says it is estimated', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: StatusStrip(speedKmh: 182, peakSpeedKmh: 241, strokeCount: 3)),
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
    expect(record.isDoubles, isFalse);
    // A doubles session draws the doubles court before any partner is seen.
    expect(state.copyWith(doubles: true).record.isDoubles, isTrue);
  });

  testWidgets('the live start names the chosen stroke model', (tester) async {
    const health = Health(
      version: '0.1.0',
      schemaVersion: '1.4',
      device: 'cpu',
      authRequired: false,
      stages: kAllStages,
      strokeModels: ['cnn', 'rf'],
    );
    // Tall enough that the setup list builds the choice below the match settings.
    final sockets = await pumpLive(
      tester,
      size: const Size(1280, 1800),
      api: FakeApiClient(health: health),
    );
    await tester.ensureVisible(find.text('Random Forest'));
    await tester.tap(find.text('Random Forest'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Start without court'));
    await startWithoutCourt(tester);
    expect(sockets.single.sent.first['stroke_model'], 'rf');
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a server without the stroke model choice gets none', (tester) async {
    final sockets = await pumpLive(tester, size: laptop);
    expect(find.text('Stroke model'), findsNothing);
    await startWithoutCourt(tester);
    expect(sockets.single.sent.first.containsKey('stroke_model'), isFalse);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the screen stays on while live, and Stop asks once rallies exist (T12.6)', (
    tester,
  ) async {
    final sockets = await pumpLive(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    final awake = container.read(screenAwakeProvider) as FakeScreenAwake;
    expect(awake.on, isFalse);
    await startWithoutCourt(tester);
    expect(awake.on, isTrue);
    sockets.single.emit({
      'type': 'score',
      'score': {'near': 1, 'far': 0},
      'rallies': [
        {'index': 0, 'start_frame': 0, 'end_frame': 10, 'winner': 'near'},
      ],
    });
    await events(tester);
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(find.text('Stop and save this session?'), findsOneWidget);
    await tester.tap(find.text('Keep going'));
    await tester.pumpAndSettle();
    expect(sockets.single.sent.last['type'], isNot('stop'));
    await tapStop(tester);
    expect(sockets.single.sent.last['type'], 'stop');
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(awake.on, isFalse);
  });

  testWidgets('keyboard: N / F award, Z undoes; a won match offers to stop (T12.6)', (
    tester,
  ) async {
    final sockets = await pumpLive(tester, size: const Size(1280, 800));
    await startWithoutCourt(tester);
    final socket = sockets.single;
    Future<void> ack(Map<String, dynamic> score) async {
      socket.emit({'type': 'score', 'score': score, 'rallies': <dynamic>[]});
      await events(tester);
    }

    expect(find.byKey(const Key('live-keys')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pump();
    expect(socket.sent.last, containsPair('winner', 'near'));
    await ack({'near': 1, 'far': 0});
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(socket.sent.last, containsPair('winner', 'far'));
    await ack({'near': 1, 'far': 1});
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.pump();
    expect(socket.sent.last['type'], 'undo');
    await ack({'near': 21, 'far': 3, 'match_winner': 'near'});
    expect(find.byKey(const Key('match-over')), findsOneWidget);
    // Nothing left to score: N no longer awards.
    final sent = socket.sent.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pump();
    expect(socket.sent.length, sent);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a silent connection is resumed instead of waited on', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    final first = sockets.single;
    expect(first.frames, isNotEmpty); // frames are on their way and nothing comes back
    await tester.pump(kStallTimeout - const Duration(seconds: 1));
    expect(sockets, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    await events(tester);
    expect(find.text('Reconnecting and refreshing the score…'), findsOneWidget);
    expect(first.closed, isTrue);
    await tester.pump(const Duration(seconds: 1));
    await events(tester);
    await tester.pump(const Duration(milliseconds: 100));
    expect(sockets, hasLength(2));
    expect(sockets.last.sent.first, {'type': 'resume', 'session_id': 's1'});
    // An answering server is left alone.
    for (var i = 0; i < 30; i++) {
      sockets.last.emit(frameEvent(sockets.last.frames.length - 1));
      await tester.pump(const Duration(seconds: 1));
    }
    expect(sockets, hasLength(2));
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('captures are skipped while the server is behind', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    await tester.pump(const Duration(seconds: 3)); // 45 captures at 15 fps if unlimited
    expect(socket.frames, hasLength(kMaxFramesInFlight));
    socket.emit(frameEvent(kMaxFramesInFlight - 1)); // the server caught up
    await events(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(socket.frames, hasLength(2 * kMaxFramesInFlight));
    // A refused frame has no frame event; it must not block the stream for good.
    socket.emit({'type': 'error', 'code': 'bad_frame', 'detail': 'frame too short'});
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(socket.frames.length, greaterThan(2 * kMaxFramesInFlight));
    socket.emit(frameEvent(socket.frames.length - 1));
    await events(tester);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('leaving the screen mid-session tells the server to save it', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    socket.emit(frameEvent(0));
    await events(tester);
    expect(socket.sent.where((m) => m['type'] == 'stop'), isEmpty);
    await tester.pumpWidget(const SizedBox()); // another mode or server replaces the screen
    await tester.pump(const Duration(seconds: 1));
    expect(socket.sent.last, {'type': 'stop'});
    expect(socket.closed, isTrue);
  });

  testWidgets('a session already stopped is not stopped again on the way out', (tester) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(sockets.single.sent.where((m) => m['type'] == 'stop'), hasLength(1));
  });

  testWidgets('a live event the app cannot read is dropped and the session goes on', (
    tester,
  ) async {
    final sockets = await pumpLive(tester);
    await startWithoutCourt(tester);
    final socket = sockets.single;
    socket.emit({'type': 'frame'}); // no frame number
    socket.emit({'type': 'hit'}); // no hit
    socket.emit({'type': 'coaching', 'coaching': 7});
    socket.emit(startedEvent()); // a second `started`
    socket.emit(frameEvent(0));
    await events(tester);
    expect(tester.takeException(), isNull);
    final container = ProviderScope.containerOf(tester.element(find.byType(LiveScreen)));
    final state = container.read(liveControllerProvider);
    expect(state.phase, LivePhase.live);
    expect(state.frames, hasLength(1));
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Open results'), findsOneWidget);
  });

  testWidgets('change of ends: the start says so, E and the menu mark one by hand', (tester) async {
    const health = Health(
      version: '0.1.0',
      schemaVersion: '1.7',
      device: 'cpu',
      authRequired: false,
      stages: kAllStages,
    );
    final sockets = await pumpLive(
      tester,
      size: const Size(1280, 800),
      api: FakeApiClient(health: health),
    );
    await tester.pump();
    await startWithoutCourt(tester);
    final socket = sockets.single;
    expect(socket.sent.first['auto_change_ends'], isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(socket.sent.last['type'], 'ends');
    socket.emit({
      'type': 'score',
      'score': {'near': 0, 'far': 0, 'ends_swapped': true},
      'rallies': <dynamic>[],
      'decision_id': socket.sent.last['decision_id'],
    });
    await events(tester);
    expect(find.byKey(const Key('ends-changed')), findsOneWidget);
    await tester.tap(find.byKey(const Key('decision-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Players changed ends'));
    await tester.pumpAndSettle();
    expect(socket.sent.where((m) => m['type'] == 'ends'), hasLength(2));
    socket.emit({
      'type': 'score',
      'score': {'near': 0, 'far': 0},
      'rallies': <dynamic>[],
      'decision_id': socket.sent.last['decision_id'],
    });
    await events(tester);
    expect(find.byKey(const Key('ends-changed')), findsNothing);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('an older server gets no change-of-ends key or menu item', (tester) async {
    final sockets = await pumpLive(tester, size: const Size(1280, 800));
    await startWithoutCourt(tester);
    final sent = sockets.single.sent.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pump();
    expect(sockets.single.sent.length, sent);
    await tapStop(tester);
    await events(tester);
    await tester.pump(const Duration(seconds: 1));
  });
}
