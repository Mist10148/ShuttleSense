import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/chat/chat_screen.dart';
import 'package:shuttlesense_app/features/connect/connect_screen.dart';
import 'package:shuttlesense_app/features/history/history_screen.dart';
import 'package:shuttlesense_app/features/mode/mode_screen.dart';
import 'package:shuttlesense_app/features/settings/settings_screen.dart';
import 'package:shuttlesense_app/features/upload/upload_screen.dart';

import 'helpers.dart';

/// T4.11: tap targets are large enough and labelled, and text meets contrast guidelines.
void main() {
  final screens = <String, Widget>{
    'connect': const ConnectScreen(),
    'upload': const UploadScreen(),
    'history': const HistoryScreen(),
    'settings': const SettingsScreen(),
  };

  for (final MapEntry(key: name, value: screen) in screens.entries) {
    testWidgets('$name meets the tap target and label guidelines', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpScreen(tester, screen);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      semantics.dispose();
    });
  }

  // T4.11: every screen that runs without a video player, at 200% text on a 360 dp phone.
  // An overflow (clipped text) is reported as an exception. The live screen is covered in
  // live_test.dart, the results screen needs media_kit.
  final scaled = <String, Widget>{
    ...screens,
    'mode': const ModeScreen(),
    'chat': const ChatScreen(jobId: 'job1'),
  };
  for (final MapEntry(key: name, value: screen) in scaled.entries) {
    testWidgets('$name survives 200% text size on a phone', (tester) async {
      await pumpScreen(
        tester,
        MediaQuery.withClampedTextScaling(minScaleFactor: 2, maxScaleFactor: 2, child: screen),
        size: const Size(360, 780),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
