import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/connect/connect_screen.dart';
import 'package:shuttlesense_app/features/upload/upload_controller.dart';
import 'package:shuttlesense_app/features/upload/upload_screen.dart';

import 'fakes/fake_api_client.dart';
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

    test('formatBytes', () {
      expect(formatBytes(350 * 1024 * 1024), '350.0 MB');
      expect(formatBytes(1288490189), '1.20 GB');
    });
  });
}
