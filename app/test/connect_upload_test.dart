import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/connect/connect_screen.dart';
import 'package:shuttlesense_app/features/upload/upload_controller.dart';
import 'package:shuttlesense_app/features/upload/upload_screen.dart';

import 'fakes/fake_api_client.dart';
import 'fakes/fake_file_picker.dart';
import 'helpers.dart';

Health health({String schema = '1.0', bool auth = false, List<String> stages = kAllStages}) =>
    Health(
      version: '0.2.0',
      schemaVersion: schema,
      device: 'cuda',
      authRequired: auth,
      stages: stages,
    );

void main() {
  group('ServerConfig', () {
    test('validateUrl', () {
      expect(ServerConfig.validateUrl(''), 'Enter the server address');
      expect(ServerConfig.validateUrl('192.168.1.20:8000'), isNull);
      expect(ServerConfig.validateUrl('https://abc.trycloudflare.com'), isNull);
      expect(ServerConfig.validateUrl('http://'), isNotNull);
      expect(ServerConfig.validateUrl('my server'), isNotNull);
    });

    test('leaving the server does not fall back to a build-time default', () async {
      SharedPreferences.setMockInitialValues({'server.baseUrl': 'http://10.0.0.5:8000'});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      expect(container.read(serverConfigProvider)!.baseUrl, 'http://10.0.0.5:8000');
      await container.read(serverConfigProvider.notifier).clear();
      expect(prefs.getString('server.baseUrl'), ''); // kept, so the default is not used
      container.invalidate(serverConfigProvider);
      expect(container.read(serverConfigProvider), isNull);
    });

    test('mixed content only for https pages calling http servers', () {
      expect(ServerConfig.isMixedContent('https', 'http://192.168.1.20:8000'), isTrue);
      expect(ServerConfig.isMixedContent('https', 'https://x.trycloudflare.com'), isFalse);
      expect(ServerConfig.isMixedContent('http', 'http://192.168.1.20:8000'), isFalse);
    });
  });

  group('Connect screen', () {
    testWidgets('bad address shows an error without a request', (tester) async {
      var checked = 0;
      await pumpScreen(
        tester,
        const ConnectScreen(),
        overrides: [
          healthCheckProvider.overrideWithValue((_) async {
            checked++;
            return health();
          }),
        ],
      );
      await tester.enterText(find.byType(TextField).first, 'my server');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.textContaining('does not look like an address'), findsOneWidget);
      expect(checked, 0);
    });

    testWidgets('token required by the server', (tester) async {
      await pumpScreen(
        tester,
        const ConnectScreen(),
        overrides: [healthCheckProvider.overrideWithValue((_) async => health(auth: true))],
      );
      await tester.enterText(find.byType(TextField).first, '10.0.0.5:8000');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.text('This server needs an access token'), findsOneWidget);
    });

    testWidgets('schema mismatch asks before connecting', (tester) async {
      await pumpScreen(
        tester,
        const ConnectScreen(),
        overrides: [healthCheckProvider.overrideWithValue((_) async => health(schema: '2.0'))],
      );
      await tester.enterText(find.byType(TextField).first, '10.0.0.5:8000');
      await tester.tap(find.text('Connect'));
      await tester.pump(); // the spinner keeps animating while the dialog is open
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Different data format'), findsOneWidget);
      await tester.tap(find.text('Connect anyway'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Connected: ShuttleSense 0.2.0 on CUDA'), findsOneWidget);
    });

    testWidgets('recent servers become chips', (tester) async {
      await pumpScreen(
        tester,
        const ConnectScreen(),
        prefs: {
          'server.recent': ['http://10.0.0.5:8000', 'https://abc.trycloudflare.com'],
        },
        overrides: [
          healthCheckProvider.overrideWithValue(
            (_) async => throw ApiException('Cannot reach server'),
          ),
        ],
      );
      await tester.tap(find.text('https://abc.trycloudflare.com'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'https://abc.trycloudflare.com',
      );
    });
  });

  group('Upload screen', () {
    testWidgets('court overlays need calibration and missing stages are disabled', (tester) async {
      final api = FakeApiClient(
        health: health(stages: ['io', 'pose', 'court', 'hits', 'analytics', 'render']),
      );
      await pumpScreen(tester, const UploadScreen(), api: api);
      FilterChip chip(String label) =>
          tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));
      expect(chip('Shuttle trail').onSelected, isNull); // tracking not installed
      expect(chip('Stroke labels').onSelected, isNull); // strokes not installed
      expect(chip('Player boxes').onSelected, isNotNull);
      expect(chip('Minimap').onSelected, isNotNull);

      await tester.tap(find.text('Calibrate court'));
      await tester.pumpAndSettle();
      expect(chip('Minimap').onSelected, isNull);
      expect(chip('Court outline').selected, isFalse);
    });

    testWidgets('turning calibration off and on again keeps the court overlays', (tester) async {
      await pumpScreen(tester, const UploadScreen(), size: tablet);
      FilterChip chip(String label) =>
          tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));
      expect(chip('Court outline').selected, isTrue);
      await tester.tap(find.text('Calibrate court'));
      await tester.pumpAndSettle();
      expect(chip('Court outline').selected, isFalse); // greyed out
      await tester.tap(find.text('Calibrate court'));
      await tester.pumpAndSettle();
      expect(chip('Court outline').selected, isTrue);
    });

    testWidgets('overlay choices are remembered', (tester) async {
      await pumpScreen(
        tester,
        const UploadScreen(),
        prefs: {
          'options.overlays': <String>['boxes'],
        },
      );
      final boxes = tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Player boxes'));
      final pose = tester.widget<FilterChip>(find.widgetWithText(FilterChip, 'Skeletons'));
      expect(boxes.selected, isTrue);
      expect(pose.selected, isFalse);
    });

    const mb = 1024 * 1024;

    /// Picks a [size]-byte "rally.mp4" with calibration off, so a finished upload starts the job.
    Future<(FakeApiClient, List<String>)> pickVideo(WidgetTester tester, {int? size = mb}) async {
      FilePickerPlatform.instance = FakeFilePicker([FakePickedFile('rally.mp4', size)]);
      final api = FakeApiClient()..uploadGate = Completer<void>();
      final visited = await pumpScreen(
        tester,
        const UploadScreen(),
        api: api,
        size: tablet,
        prefs: {'options.calibrate': false},
      );
      await tester.tap(find.text('Choose video'));
      await tester.pumpAndSettle();
      return (api, visited);
    }

    Future<void> startUpload(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Upload and analyze'));
      await tester.tap(find.text('Upload and analyze'));
      await tester.pump();
    }

    testWidgets('upload shows progress, then starts the job', (tester) async {
      final (api, visited) = await pickVideo(tester, size: 10 * mb);
      expect(find.text('rally.mp4'), findsOneWidget);
      await startUpload(tester);
      expect(find.text('Uploading 5.0 MB of 10.0 MB (50%)'), findsOneWidget);
      expect(
        tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value,
        0.5,
      );
      api.uploadGate!.complete();
      await tester.pumpAndSettle();
      expect(api.calls, contains('createJob vid1 ${api.calls.last.split(' ').last}'));
      expect(visited, ['/jobs/job2']);
    });

    testWidgets('cancel resets the upload without an error', (tester) async {
      final (api, visited) = await pickVideo(tester);
      await startUpload(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.uploadCancel!.isCancelled, isTrue);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Cancelled'), findsNothing);
      expect(find.text('Upload and analyze'), findsOneWidget); // file kept for a retry
      expect(visited, isEmpty);
    });

    testWidgets('a failed upload shows the server message', (tester) async {
      final (api, _) = await pickVideo(tester);
      api.uploadError = ApiException('Video is longer than 5 minutes', statusCode: 400);
      await startUpload(tester);
      api.uploadGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Video is longer than 5 minutes'), findsOneWidget);
      expect(find.text('Upload and analyze'), findsOneWidget);
    });

    testWidgets('leaving the screen cancels the upload', (tester) async {
      final (api, _) = await pickVideo(tester);
      await startUpload(tester);
      await tester.pumpWidget(const SizedBox());
      expect(api.uploadCancel!.isCancelled, isTrue);
    });

    testWidgets('a file of unknown size is not accepted', (tester) async {
      final (api, _) = await pickVideo(tester, size: null);
      expect(find.textContaining('Could not read the size'), findsOneWidget);
      expect(find.text('rally.mp4'), findsNothing);
      expect(api.calls.where((c) => c.startsWith('uploadVideo')), isEmpty);
    });

    test('browser uploads have a lower cap', () {
      expect(uploadSizeProblem(600 * mb, web: false), isNull);
      expect(uploadSizeProblem(600 * mb, web: true), contains('at most 512.0 MB'));
      expect(uploadSizeProblem(0, web: false), 'This file is empty.');
    });

    test('formatBytes', () {
      expect(formatBytes(350 * 1024 * 1024), '350.0 MB');
      expect(formatBytes(1288490189), '1.20 GB');
    });
  });
}
