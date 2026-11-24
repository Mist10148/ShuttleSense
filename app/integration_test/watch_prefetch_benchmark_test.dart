// Run against the isolated local benchmark server, never a shared backend.
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
const depthPath = String.fromEnvironment('BENCH_DEPTH_FILE');
const server = String.fromEnvironment('BENCH_SERVER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('alternating fixed-section Watch trials', (tester) async {
    expect(videoPath, isNotEmpty);
    expect(depthPath, isNotEmpty);
    expect(server, isNotEmpty);
    MediaKit.ensureInitialized();
    final video = File(videoPath);
    expect(video.existsSync(), isTrue);
    FilePickerPlatform.instance = PickOneFile(LocalFile(video));

    // A short preliminary session warms the models in this same server process.
    for (final (trial, depth) in <(int, int)>[
      (0, 0),
      (1, 0),
      (2, 2),
      (3, 0),
      (4, 2),
      (5, 0),
      (6, 2),
    ]) {
      File(depthPath).writeAsStringSync('$depth');
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
      debugPrint('BENCH_TRIAL_START $trial $depth');
      await tapText(tester, 'Start analysis');
      if (trial == 0) {
        await pumpUntil(tester, find.textContaining('1.0 s / 21.0 s'));
        await tapText(tester, 'Stop and save');
      }
      await pumpUntil(
        tester,
        find.textContaining('Session saved'),
        timeout: const Duration(minutes: 5),
      );
      debugPrint('BENCH_TRIAL_SAVED $trial $depth');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
