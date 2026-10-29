import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/features/results/downloads.dart';
import 'package:shuttlesense_app/features/results/widgets/summary_chart.dart';
import 'package:shuttlesense_app/features/results/widgets/video_panel.dart';

import 'fakes/fake_api_client.dart';

class FakeTargets extends SaveTargets {
  FakeTargets(this.dir);

  final Directory dir;
  final events = <String>[];

  @override
  Future<void> openInBrowser(String url) async => events.add('open $url');

  @override
  Future<String?> saveAs(String fileName, Uint8List bytes) async {
    events.add('saveAs $fileName ${bytes.length}');
    return '${dir.path}/$fileName';
  }

  @override
  Future<String> tempPath(String fileName) async => '${dir.path}/$fileName';

  @override
  Future<void> share(String path, String fileName) async => events.add('share $fileName');
}

class FakeTarget implements PlaybackTarget {
  @override
  Duration position = const Duration(seconds: 1);
  @override
  bool playing = true;
  final rates = <double>[];

  @override
  Future<void> playOrPause() async => playing = !playing;
  @override
  Future<void> seek(Duration p) async => position = p;
  @override
  Future<void> setRate(double rate) async => rates.add(rate);
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ss_dl'));
  tearDown(() => dir.deleteSync(recursive: true));

  group('saveExport', () {
    test('web opens the token URL in the browser', () async {
      final targets = FakeTargets(dir);
      final path = await saveExport(
        FakeApiClient(),
        'job1',
        ExportFile.hitsCsv,
        method: SaveMethod.browser,
        targets: targets,
      );
      expect(path, isNull);
      expect(targets.events, ['open http://fake:8000/jobs/job1/hits.csv']);
    });

    test('desktop downloads, then asks where to save', () async {
      final api = FakeApiClient();
      final targets = FakeTargets(dir);
      final progress = <double>[];
      final path = await saveExport(
        api,
        'job1',
        ExportFile.ralliesCsv,
        method: SaveMethod.saveDialog,
        targets: targets,
        onProgress: progress.add,
      );
      expect(api.calls.single, 'download http://fake:8000/jobs/job1/rallies.csv');
      expect(targets.events, ['saveAs job1_rallies.csv 4']);
      expect(path, endsWith('job1_rallies.csv'));
      expect(progress, [1.0]);
    });

    test('mobile downloads to a temp file and opens the share sheet', () async {
      final targets = FakeTargets(dir);
      final path = await saveExport(
        FakeApiClient(),
        'job1',
        ExportFile.video,
        method: SaveMethod.share,
        targets: targets,
      );
      expect(File(path!).existsSync(), isTrue);
      expect(targets.events, ['share job1_annotated.mp4']);
    });
  });

  testWidgets('summary chart renders with the golden record', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: SummaryChart(summary: goldenRecord().summary)),
      ),
    );
    expect(find.text('Strokes by player'), findsOneWidget);
    expect(find.textContaining('Near: 2 hits, peak 241 km/h'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('frame steps pause and move one frame', () async {
    final target = FakeTarget();
    await stepFrame(target, 25, 1);
    expect(target.playing, isFalse);
    expect(target.position, const Duration(milliseconds: 1040));
    await stepFrame(target, 25, -1);
    await stepFrame(target, 25, -1);
    expect(target.position, const Duration(milliseconds: 960));
    target.position = Duration.zero;
    await stepFrame(target, 25, -1);
    expect(target.position, Duration.zero);
  });

  testWidgets('speed buttons and shortcuts drive the player', (tester) async {
    final target = FakeTarget()..playing = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackShortcuts(
            target: target,
            fps: 25,
            child: PlaybackControls(target: target, fps: 25),
          ),
        ),
      ),
    );
    await tester.tap(find.text('0.5×'));
    expect(target.rates, [0.5]);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(target.playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(target.playing, isFalse);
    expect(target.position, const Duration(milliseconds: 1040));
  });
}
