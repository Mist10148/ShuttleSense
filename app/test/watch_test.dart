import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shuttlesense_app/shared/widgets/tactile.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/repositories/analysis_repository.dart';
import 'package:shuttlesense_app/features/mode/mode_screen.dart';
import 'package:shuttlesense_app/features/calibration/calibration_screen.dart';
import 'package:shuttlesense_app/features/watch/watch_screen.dart';
import 'package:shuttlesense_app/features/watch/court_geometry.dart';
import 'package:shuttlesense_app/shared/widgets/surfaces.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'fakes/fake_api_client.dart';
import 'fakes/fake_file_picker.dart';
import 'helpers.dart';

class _SuggestionApi extends FakeApiClient {
  List<({double x, double y})>? sentCorners;
  @override
  Future<Map<String, dynamic>> suggestMatchType(
    String videoId,
    List<({double x, double y})> corners,
  ) async {
    sentCorners = corners;
    return {'suggestion': 'doubles', 'detail': 'Please confirm.'};
  }
}

class _WatchSink extends Fake implements WebSocketSink {
  final messages = <Map<String, dynamic>>[];

  @override
  void add(dynamic data) => messages.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
}

class _WatchSocket extends Fake implements WebSocketChannel {
  final incoming = StreamController<dynamic>.broadcast(sync: true);
  final _WatchSink outgoing = _WatchSink();

  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  WebSocketSink get sink => outgoing;
  @override
  Future<void> get ready async {}

  void send(Map<String, dynamic> message) => incoming.add(jsonEncode(message));
}

void main() {
  testWidgets('pause holds an in-flight frame until resume and stop sends no next', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    final socket = _WatchSocket();
    addTearDown(socket.incoming.close);
    await pumpScreen(
      tester,
      WatchScreen(channelFactory: (_) => socket),
      size: laptop,
      api: FakeApiClient(),
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '1',
            schemaVersion: '1',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
            watchRealtime: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analyze every frame'));
    await tester.pump();
    await tester.ensureVisible(find.text('Singles'));
    await tester.pump();
    await tester.tap(find.text('Singles'));
    await tester.pump();
    await tester.ensureVisible(find.text('Start analysis'));
    await tester.pump();
    await tester.tap(find.text('Start analysis'));
    await tester.pump();
    expect(socket.outgoing.messages.first['type'], 'start');
    socket.send({
      'type': 'started',
      'fps': 25,
      'frames': 10,
      'width': 1,
      'height': 1,
      'stages': {'synthetic': true},
    });
    await tester.pumpAndSettle();
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
        {'type': 'frame', 'frame': 0},
      ],
    });
    await tester.pump(const Duration(milliseconds: 100));
    expect(socket.outgoing.messages.where((m) => m['type'] == 'next'), hasLength(1));
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.text('Play'));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
    expect(socket.outgoing.messages.where((m) => m['type'] == 'next'), hasLength(2));
    await tester.ensureVisible(find.text('Stop and save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop and save'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(socket.outgoing.messages.last['type'], 'stop');
    expect(socket.outgoing.messages.where((m) => m['type'] == 'next'), hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  test('frame pacing subtracts processing time and never waits below zero', () {
    expect(watchFrameDelay(25, const Duration(milliseconds: 10)), const Duration(milliseconds: 30));
    expect(watchFrameDelay(25, const Duration(milliseconds: 40)), Duration.zero);
    expect(watchFrameDelay(25, const Duration(milliseconds: 100)), Duration.zero);
  });

  test('watch elapsed time is a wall-clock duration with hours', () {
    expect(formatWatchElapsed(Duration.zero), '00:00:00');
    expect(formatWatchElapsed(const Duration(minutes: 2, seconds: 9)), '00:02:09');
    expect(formatWatchElapsed(const Duration(hours: 12, minutes: 3, seconds: 4)), '12:03:04');
  });

  test('acceleration diagnostics show actual provider and fallback', () {
    expect(formatWatchAcceleration(null), isNull);
    expect(
      formatWatchAcceleration({
        'models': {
          'detector': {'active': 'cuda'},
          'pose': {'active': 'cuda', 'fallback_reason': 'unavailable'},
        },
      }),
      'Detector: CUDA · Pose: CUDA (fallback)',
    );
  });

  Health health(bool enabled) => Health(
    version: '0.1',
    schemaVersion: '1.6',
    device: 'cpu',
    authRequired: false,
    stages: const [],
    watchVideo: enabled,
    practiceVideo: enabled,
  );

  testWidgets('watch mode is available only when the backend advertises it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await pumpScreen(
      tester,
      const ModeScreen(),
      size: laptop,
      overrides: [healthProvider.overrideWith((ref) async => health(false))],
    );
    final disabled = tester.widget<PastelActionCard>(
      find.ancestor(of: find.text('Watch & Analyze'), matching: find.byType(PastelActionCard)),
    );
    expect(disabled.onTap, isNull);
    final coach = tester.widget<PastelActionCard>(
      find.ancestor(of: find.text('AI Coach'), matching: find.byType(PastelActionCard)),
    );
    expect(coach.onTap, isNull);
    expect(coach.description, contains('Requires a backend'));
    await tester.pumpWidget(const SizedBox());
    await pumpScreen(
      tester,
      const ModeScreen(),
      size: laptop,
      overrides: [healthProvider.overrideWith((ref) async => health(true))],
    );
    final enabled = tester.widget<PastelActionCard>(
      find.ancestor(of: find.text('Watch & Analyze'), matching: find.byType(PastelActionCard)),
    );
    expect(enabled.onTap, isNotNull);
    final enabledCoach = tester.widget<PastelActionCard>(
      find.ancestor(of: find.text('AI Coach'), matching: find.byType(PastelActionCard)),
    );
    expect(enabledCoach.onTap, isNotNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('manual format must be chosen and auto requires court corners', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    await pumpScreen(
      tester,
      const WatchScreen(),
      size: laptop,
      api: FakeApiClient(),
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '0.1',
            schemaVersion: '1.6',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
            watchMatchType: true,
            watchRealtime: true,
            watchBackground: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    final faster = find.widgetWithText(TactileSwitchTile, 'Faster player analysis (experimental)');
    expect(tester.widget<TactileSwitchTile>(faster).value, isFalse);
    await tester.tap(faster);
    await tester.pump();
    expect(tester.widget<TactileSwitchTile>(faster).value, isTrue);
    expect(
      tester
          .widget<DepthSegmented<bool>>(
            find.ancestor(of: find.text('Real time'), matching: find.byType(DepthSegmented<bool>)),
          )
          .selected,
      {true},
    );
    await tester.tap(find.text('Analyze every frame'));
    await tester.pump();
    expect(find.textContaining('Playback waits for every normalized frame'), findsOneWidget);
    await tester.ensureVisible(find.text('Start analysis'));
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('Doubles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doubles'));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNotNull,
    );
    await tester.ensureVisible(find.text('Suggest automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest automatically'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Suggest match format'));
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Suggest match format'))
          .onPressed,
      isNull,
    );
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNull,
    );
  });

  testWidgets('court corners can be suggested after choosing a format and cleared', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    final api = FakeApiClient()
      ..suggestedCorners = [
        (x: 200.0, y: 650.0),
        (x: 1000.0, y: 650.0),
        (x: 800.0, y: 200.0),
        (x: 400.0, y: 200.0),
      ];
    await pumpScreen(
      tester,
      const WatchScreen(),
      size: laptop,
      api: api,
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '1',
            schemaVersion: '1',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Find corners automatically'))
          .onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('Doubles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doubles'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Check the suggested outer court corners'), findsOneWidget);
    final canvas = tester.widget<CornerCanvas>(find.byType(CornerCanvas));
    expect(canvas.corners, hasLength(4));
    expect(canvas.overlayPainter, isNotNull);
    final singles = fullToSingles(canvas.corners)!;
    for (var i = 0; i < 4; i++) {
      expect(singles[i].x, closeTo(api.suggestedCorners![i].x, 0.001));
      expect(singles[i].y, closeTo(api.suggestedCorners![i].y, 0.001));
    }
    await tester.ensureVisible(find.text('Clear corners'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear corners'));
    await tester.pumpAndSettle();
    expect(tester.widget<CornerCanvas>(find.byType(CornerCanvas)).corners, isEmpty);
  });

  testWidgets('failed court detection leaves manual placement available', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    await pumpScreen(
      tester,
      const WatchScreen(),
      size: laptop,
      api: FakeApiClient(),
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '1',
            schemaVersion: '1',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Singles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Singles'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Find corners automatically'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not find the court reliably'), findsOneWidget);
    tester.widget<CornerCanvas>(find.byType(CornerCanvas)).onTap((x: 200, y: 650));
    await tester.pump();
    expect(tester.widget<CornerCanvas>(find.byType(CornerCanvas)).corners, hasLength(1));
  });

  testWidgets('automatic suggestion requires confirmation and can be overridden', (tester) async {
    FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', 1000)]);
    final api = _SuggestionApi();
    await pumpScreen(
      tester,
      const WatchScreen(),
      size: laptop,
      api: api,
      overrides: [
        healthProvider.overrideWith(
          (ref) async => const Health(
            version: '0.1',
            schemaVersion: '1.6',
            device: 'cpu',
            authRequired: false,
            stages: [],
            watchVideo: true,
            watchMatchType: true,
            watchRealtime: true,
            watchBackground: true,
          ),
        ),
      ],
    );
    await tester.tap(find.text('Choose video'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Suggest automatically'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest automatically'));
    await tester.pumpAndSettle();
    for (final point in [
      (x: 100.0, y: 650.0),
      (x: 1180.0, y: 650.0),
      (x: 800.0, y: 90.0),
      (x: 480.0, y: 90.0),
    ]) {
      tester.widget<CornerCanvas>(find.byType(CornerCanvas)).onTap(point);
      await tester.pump();
    }
    await tester.ensureVisible(find.text('Suggest match format'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Suggest match format'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Suggested: doubles'), findsOneWidget);
    expect(api.sentCorners, isNotNull);
    expect(api.sentCorners!.first.x, greaterThan(100));
    expect(api.sentCorners![1].x, lessThan(1180));
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNull,
    );
    await tester.ensureVisible(find.text('Singles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Singles'));
    await tester.pump();
    expect(
      tester
          .widget<DepthSegmented<String>>(
            find.ancestor(of: find.text('Singles'), matching: find.byType(DepthSegmented<String>)),
          )
          .selected,
      {'singles'},
    );
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start analysis')).onPressed,
      isNotNull,
    );
  });
}
