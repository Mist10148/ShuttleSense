// The theme gallery (docs/THEMES.md) draws every theme at once without overflowing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/styleguide/theme_gallery_screen.dart';

import 'helpers.dart';

void main() {
  for (final MapEntry(key: name, value: size) in kSizes.entries) {
    testWidgets('every theme renders in the gallery on a $name', (tester) async {
      await pumpScreen(tester, const ThemeGalleryScreen(), size: size);
      expect(tester.takeException(), isNull);
      for (final (skin, brightness) in ThemeGalleryScreen.variants) {
        final panel = find.byKey(ValueKey('gallery-${skin.name}-${brightness.name}'));
        await tester.scrollUntilVisible(panel, 300);
        expect(panel, findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('each panel is labelled for screen readers', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpScreen(tester, const ThemeGalleryScreen(), size: laptop);
    expect(find.bySemanticsLabel(RegExp('Backrooms theme preview')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'Classic \(Dark\) theme preview')), findsOneWidget);
    handle.dispose();
  });
}
