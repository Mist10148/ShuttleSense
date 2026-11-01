import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/config/app_mode.dart';
import 'package:shuttlesense_app/features/live/frame_source.dart';
import 'package:shuttlesense_app/features/live/live_controller.dart';
import 'package:shuttlesense_app/features/live/live_screen.dart';
import 'package:shuttlesense_app/features/live/live_socket.dart';
import 'package:shuttlesense_app/features/mode/mode_screen.dart';

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

  test('live state builds a clip record for the shared widgets', () {
    const state = LiveState(sessionId: 's', size: (width: 1280, height: 720));
    final record = state.record;
    expect(record.isLive, isTrue);
    expect(record.width, 1280);
    expect(record.courtCorners, isNull);
  });
}
