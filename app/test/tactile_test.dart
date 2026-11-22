import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/shared/widgets/tactile.dart';

void main() {
  for (final (name, theme) in [('light', AppTheme.light()), ('dark', AppTheme.dark())]) {
    testWidgets('a key cap calls onTap when tapped ($name)', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(
              child: KeyCap(
                onTap: () => taps++,
                tooltip: 'Start',
                semanticLabel: 'Go',
                child: const Text('Go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(taps, 1);

      // A mouse hovers first, then clicks: the key lifts and sinks under the pointer.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Go')));
      await tester.pumpAndSettle();
      await mouse.down(tester.getCenter(find.text('Go')));
      await tester.pump(const Duration(milliseconds: 40));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(taps, 2);
    });
  }
}
