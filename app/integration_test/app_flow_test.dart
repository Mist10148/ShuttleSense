// End-to-end flow of the real app against a running backend (T7.4, checklist rows 1, 2, 4,
// 5 and 9). Start the backend with the fake pipeline, then run on a device:
//
//   SHUTTLESENSE_FAKE_PIPELINE=1 uvicorn shuttlesense.api.main:app --port 8000   (backend/)
//   flutter test integration_test -d windows \
//     --dart-define=E2E_SERVER=http://127.0.0.1:8000 \
//     --dart-define=E2E_VIDEO=C:/path/to/rally.mp4
//
// On a phone use the laptop's LAN address and a video path on the phone. The file picker is
// replaced so the run needs no clicks; everything else (HTTP, polling, routing, playback) is
// the shipped code. Without the two defines the test is skipped.
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/app.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';

const server = String.fromEnvironment('E2E_SERVER');
const videoPath = String.fromEnvironment('E2E_VIDEO');

/// A video on this device's disk, as the picker would return it.
final class LocalFile extends PlatformFile {
  LocalFile(this.file);

  final File file;

  @override
  String get name => file.uri.pathSegments.last;

  @override
  Uri get uri => file.uri;

  @override
  get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => file.lengthSync();

  @override
  Future<int?> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() => file.openRead().map(Uint8List.fromList);
}

class PickOneFile extends FilePickerPlatform {
  PickOneFile(this.file);

  final PlatformFile file;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => [file];
}

/// Pumps until [finder] matches, failing after [timeout] (spinners never settle).
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 90),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  final shown = find
      .byType(Text)
      .evaluate()
      .map((e) => (e.widget as Text).data)
      .whereType<String>()
      .join(' | ');
  fail('timed out waiting for $finder; on screen: $shown');
}

/// Focuses [field] with a tap first: on a desktop window a second enterText otherwise goes
/// to the input connection of whatever had focus before.
Future<void> typeInto(WidgetTester tester, Finder field, String text) async {
  await tester.tap(field);
  await tester.pump();
  await tester.enterText(field, text);
  await tester.pump();
  expect(tester.widget<TextField>(field).controller!.text, text);
}

Future<void> tapText(WidgetTester tester, String text) async {
  final target = find.text(text).first;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'connect, upload, process, open the results and find the job in history',
    (tester) async {
      MediaKit.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final video = File(videoPath);
      expect(video.existsSync(), isTrue, reason: 'E2E_VIDEO $videoPath not found');
      FilePickerPlatform.instance = PickOneFile(LocalFile(video));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: const ShuttleSenseApp(),
        ),
      );
      await pumpUntil(tester, find.text('Connect to server'));

      // 1. A wrong address explains itself, then the real one connects.
      await typeInto(tester, find.byType(TextField).first, 'http://127.0.0.1:9');
      await tapText(tester, 'Connect');
      await pumpUntil(tester, find.textContaining('Cannot reach server'));
      await typeInto(tester, find.byType(TextField).first, server);
      await tester.testTextInput.receiveAction(TextInputAction.done); // Enter submits too
      await pumpUntil(tester, find.text('Upload clip'));
      await tapText(tester, 'Upload clip');
      await pumpUntil(tester, find.text('New analysis'));

      // 2. Pick and upload without calibration; 4. processing runs to the end.
      await tapText(tester, 'Calibrate court');
      await tapText(tester, 'Choose video');
      await pumpUntil(tester, find.text(LocalFile(video).name));
      await tapText(tester, 'Upload and analyze');

      // 5. Results: the golden record's strokes appear in the timeline.
      await pumpUntil(tester, find.text('Serve'));
      expect(find.text('Smash'), findsWidgets);

      // 9. History lists the job under the video's name.
      await tapText(tester, 'History');
      await pumpUntil(tester, find.text(LocalFile(video).name));
    },
    skip: server.isEmpty || videoPath.isEmpty,
  );
}
