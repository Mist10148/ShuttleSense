import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/shared/widgets/smooth_scroll.dart';
import 'package:shuttlesense_app/shared/widgets/tactile.dart';

void main() {
  testWidgets('the depth segmented control picks one option and reports it', (tester) async {
    var picked = <String>{'a'};
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => DepthSegmented<String>(
                segments: const [
                  ButtonSegment(value: 'a', label: Text('Alpha')),
                  ButtonSegment(value: 'b', label: Text('Beta')),
                  ButtonSegment(value: 'c', label: Text('Gamma'), enabled: false),
                ],
                selected: picked,
                onSelectionChanged: (s) => setState(() => picked = s),
              ),
            ),
          ),
        ),
      ),
    );
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.text('Alpha')),
      matchesSemantics(
        label: 'Alpha',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        isInMutuallyExclusiveGroup: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(picked, {'b'});
    await tester.tap(find.text('Gamma'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(picked, {'b'}); // disabled
    // Options share the width evenly.
    expect(
      tester.getSize(find.ancestor(of: find.text('Alpha'), matching: find.byType(InkWell))).width,
      closeTo(
        tester.getSize(find.ancestor(of: find.text('Beta'), matching: find.byType(InkWell))).width,
        0.01,
      ),
    );
    handle.dispose();
  });

  testWidgets('a wheel step glides instead of jumping', (tester) async {
    final controller = SmoothScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          controller: controller,
          children: [for (var i = 0; i < 50; i++) SizedBox(height: 100, child: Text('$i'))],
        ),
      ),
    );
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(tester.getCenter(find.byType(ListView))));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(controller.offset, greaterThan(0));
    expect(controller.offset, lessThan(300)); // still on its way
    // A second step adds to where it is heading.
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(600, 0.5));
  });
}
