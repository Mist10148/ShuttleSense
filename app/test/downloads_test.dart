import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
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
  Future<String?> pickSavePath(String fileName) async {
    events.add('pickSavePath $fileName');
    return cancelSave ? null : '${dir.path}/saved_$fileName';
  }

  bool cancelSave = false;

  @override
  Future<String> tempPath(String fileName) async => '${dir.path}/$fileName';

  @override
  Future<void> share(String path, String fileName) async => events.add('share $fileName');
}

class FakeTarget implements PlaybackTarget {
  @override
  Duration position = const Duration(seconds: 1);
  final _changes = StreamController<bool>.broadcast();
  bool _playing = true;
  @override
  bool get playing => _playing;
  set playing(bool value) => _changes.add(_playing = value);
  @override
  Stream<bool> get playingChanges => _changes.stream;
  final rates = <double>[];

  @override
  Future<void> playOrPause() async => playing = !playing;
  @override
  Future<void> seek(Duration p) async => position = p;
  @override
  Future<void> setRate(double rate) async => rates.add(rate);
}

/// media_kit on the web: `currentTime = position.inMilliseconds / 1000`.
class _MillisecondTarget extends FakeTarget {
  @override
  Future<void> seek(Duration p) async => position = Duration(milliseconds: p.inMilliseconds);
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

    test('desktop asks where to save, then downloads straight there', () async {
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
      expect(targets.events, ['pickSavePath job1_rallies.csv']);
      expect(path, endsWith('saved_job1_rallies.csv'));
      expect(File(path!).readAsStringSync(), 'data');
      expect(File('${dir.path}/job1_rallies.csv').existsSync(), isFalse); // no temp copy
      expect(progress, [1.0]);
    });

    test('desktop save cancelled in the dialog downloads nothing', () async {
      final api = FakeApiClient();
      final targets = FakeTargets(dir)..cancelSave = true;
      final path = await saveExport(
        api,
        'job1',
        ExportFile.video,
        method: SaveMethod.saveDialog,
        targets: targets,
      );
      expect(path, isNull);
      expect(api.calls, isEmpty);
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
    expect(target.position, const Duration(milliseconds: 1060));
    await stepFrame(target, 25, -1);
    await stepFrame(target, 25, -1);
    expect(target.position, const Duration(milliseconds: 980));
    target.position = Duration.zero;
    await stepFrame(target, 25, -1);
    expect(target.position, Duration.zero);
  });

  test('frame steps at 30 fps land on every frame in turn', () async {
    final target = FakeTarget()..position = Duration.zero;
    for (var i = 1; i <= 90; i++) {
      await stepFrame(target, 30, 1);
      expect(frameIndexAt(target.position, 30), i);
    }
    for (var i = 89; i >= 0; i--) {
      await stepFrame(target, 30, -1);
      expect(frameIndexAt(target.position, 30), i);
    }
  });

  test('frame steps survive a player that seeks in whole milliseconds (web)', () async {
    for (final fps in [25.0, 30.0, 60.0]) {
      final target = _MillisecondTarget()..position = Duration.zero;
      for (var i = 1; i <= 120; i++) {
        await stepFrame(target, fps, 1);
        expect(frameIndexAt(target.position, fps), i, reason: '$fps fps, frame $i');
      }
      for (var i = 119; i >= 0; i--) {
        await stepFrame(target, fps, -1);
        expect(frameIndexAt(target.position, fps), i, reason: '$fps fps, frame $i');
      }
    }
  });

  testWidgets('speed buttons and shortcuts drive the player', (tester) async {
    final target = FakeTarget()..playing = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: PlaybackShortcuts(
            target: target,
            fps: 25,
            child: PlaybackControls(target: target, fps: 25),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0.5×  speed'));
    await tester.pumpAndSettle();
    expect(target.rates, [0.5]);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(target.playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(target.playing, isFalse);
    expect(target.position, const Duration(milliseconds: 1060)); // middle of frame 26
  });

  testWidgets('play button shows the state; Space on a focused button presses it', (tester) async {
    final target = FakeTarget()..playing = false;
    var pressed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: PlaybackShortcuts(
            target: target,
            fps: 25,
            child: Column(
              children: [
                PlaybackControls(target: target, fps: 25),
                TextButton(onPressed: () => pressed++, child: const Text('Other')),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('Play (Space)'), findsOneWidget);
    await tester.tap(find.byTooltip('Play (Space)'));
    await tester.pump();
    expect(find.byTooltip('Pause (Space)'), findsOneWidget);

    Focus.of(tester.element(find.text('Other'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(pressed, 1);
    expect(target.playing, isTrue); // the shortcut left Space to the button
  });
}
