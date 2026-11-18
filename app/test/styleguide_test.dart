// The /styleguide page renders every shared component in both themes without overflow.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/features/styleguide/styleguide_screen.dart';

import 'helpers.dart';

void main() {
  for (final MapEntry(key: name, value: size) in kSizes.entries) {
    testWidgets('styleguide lays out on a $name and switches to dark', (tester) async {
      setSize(tester, size);
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: const StyleguideScreen()));
      // Skeletons pulse forever, so pump a frame instead of settling.
      await tester.pump();
      expect(find.text('Styleguide'), findsOneWidget);

      await tester.tap(find.text('Dark'));
      await tester.pump();
      final theme = Theme.of(tester.element(find.text('Upload clip')));
      expect(theme.brightness, Brightness.dark);
      expect(tester.takeException(), isNull);
    });
  }
}
