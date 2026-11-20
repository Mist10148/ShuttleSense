// Exercise the same media_kit player used by Results on local benchmark exports.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

const cpuVideo = String.fromEnvironment('BENCH_X264_VIDEO');
const gpuVideo = String.fromEnvironment('BENCH_NVENC_VIDEO');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('export playback and seek', (tester) async {
    expect(cpuVideo, isNotEmpty);
    expect(gpuVideo, isNotEmpty);
    MediaKit.ensureInitialized();
    for (final path in [cpuVideo, gpuVideo]) {
      expect(File(path).existsSync(), isTrue);
      final player = Player();
      final controller = VideoController(player);
      await tester.pumpWidget(MaterialApp(home: Video(controller: controller)));
      await tester.pump();
      try {
        await tester.runAsync(() async {
          await player.open(Media(path), play: false);
          for (var i = 0; i < 100 && player.state.duration == Duration.zero; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(player.state.duration.inSeconds, greaterThanOrEqualTo(20));
          await player.seek(const Duration(seconds: 10));
          await player.play();
          final position = await player.stream.position
              .firstWhere((p) => p >= const Duration(seconds: 10))
              .timeout(const Duration(seconds: 15));
          expect(position.inSeconds, greaterThanOrEqualTo(10));
          await player.pause();
          // A second seek near the end exercises another point in the file.
          await player.seek(const Duration(seconds: 19));
          await player.play();
          final nearEnd = await player.stream.position
              .firstWhere((p) => p >= const Duration(seconds: 19))
              .timeout(const Duration(seconds: 15));
          expect(nearEnd.inSeconds, greaterThanOrEqualTo(19));
          print('BENCH_PLAYBACK_OK $path'); // ignore: avoid_print
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        await player.dispose();
      }
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
