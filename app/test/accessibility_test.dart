import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/connect/connect_screen.dart';
import 'package:shuttlesense_app/features/history/history_screen.dart';
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

  testWidgets('layouts survive 200% text size on a phone', (tester) async {
    await pumpScreen(
      tester,
      MediaQuery.withClampedTextScaling(
        minScaleFactor: 2,
        maxScaleFactor: 2,
        child: const HistoryScreen(),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
