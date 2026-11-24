// Profile-mode app benchmark against serve_watch_pose_batch_benchmark.py only.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/app.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/features/calibration/calibration_screen.dart';

import 'app_flow_test.dart' show LocalFile, PickOneFile, pumpUntil, pumpUntilCondition, tapText;

const videoPath = String.fromEnvironment('BENCH_VIDEO');
const batchPath = String.fromEnvironment('BENCH_BATCH_FILE');
const server = String.fromEnvironment('BENCH_SERVER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('fixed-profile alternating pose batch trials', (tester) async {
    expect(videoPath, isNotEmpty);
    expect(batchPath, isNotEmpty);
    expect(server, isNotEmpty);
    MediaKit.ensureInitialized();
    final video = File(videoPath);
    expect(video.existsSync(), isTrue);
    FilePickerPlatform.instance = PickOneFile(LocalFile(video));

    // First cycle uses a fresh per-setting cache; two later cycles reuse each cache.
    final batches = [4, 8, 16, 4, 8, 16, 4, 8, 16];
    for (var index = 0; index < batches.length; index++) {
      final batch = batches[index];
      File(batchPath).writeAsStringSync('$batch');
      SharedPreferences.setMockInitialValues({'server.baseUrl': server, 'ui.mode': 'watch'});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: const ShuttleSenseApp(),
        ),
      );
      await pumpUntil(tester, find.text('Choose video'));
      await tapText(tester, 'Choose video');
      await pumpUntilCondition(
        tester,
        () => tester
            .widgetList<FilledButton>(find.widgetWithText(FilledButton, 'Continue to options'))
            .any((button) => button.onPressed != null),
        'video is uploaded',
      );
      await tapText(tester, 'Continue to options');
      await pumpUntil(tester, find.text('Analyze every frame'));
      await tapText(tester, 'Analyze every frame');
      await tapText(tester, 'Doubles');
      await tapText(tester, 'Continue to calibration');
      await pumpUntil(tester, find.byType(CornerCanvas));
      for (final point in [
        (x: 449.686, y: 1011.452),
        (x: 1493.127, y: 1006.201),
        (x: 1218.424, y: 488.875),
        (x: 679.633, y: 483.143),
      ]) {
        tester.widget<CornerCanvas>(find.byType(CornerCanvas)).onTap(point);
        await tester.pump();
      }
      debugPrint('POSE_BATCH_START ${index + 1} $batch');
      await tapText(tester, 'Start analysis');
      await pumpUntil(
        tester,
        find.textContaining('Session saved'),
        timeout: const Duration(minutes: 8),
      );
      debugPrint('POSE_BATCH_SAVED ${index + 1} $batch');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
