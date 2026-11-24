import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/features/calibration/calibration_screen.dart';

/// A 1×1 transparent PNG, so the canvas has an image without the network.
final _pixel = MemoryImage(
  Uint8List.fromList(const [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, //
    0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
    0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00,
    0x01, 0x00, 0x00, 0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]),
);

void main() {
  Future<ScrollController> pump(WidgetTester tester) async {
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              CornerCanvas(
                image: _pixel,
                width: 1280,
                height: 720,
                corners: const [],
                onTap: (_) {},
                onMove: (_, _) {},
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return scroll;
  }

  double scaleOf(WidgetTester tester) => tester
      .widget<InteractiveViewer>(find.byType(InteractiveViewer))
      .transformationController!
      .value
      .getMaxScaleOnAxis();

  testWidgets('a plain wheel scrolls the page and leaves the zoom alone', (tester) async {
    final scroll = await pump(tester);
    final centre = tester.getCenter(find.byType(InteractiveViewer));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(centre));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
    await tester.pumpAndSettle();
    expect(scaleOf(tester), 1);
    expect(scroll.offset, greaterThan(0));
  });

  testWidgets('Ctrl + wheel zooms in, and Fit returns to the whole frame', (tester) async {
    await pump(tester);
    final centre = tester.getCenter(find.byType(InteractiveViewer));
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(centre));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -240)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(scaleOf(tester), greaterThan(1));
    await tester.tap(find.byTooltip('Fit the whole frame'));
    await tester.pump();
    expect(scaleOf(tester), 1);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(scaleOf(tester), closeTo(1.5, 1e-6));
    await tester.tap(find.byTooltip('Zoom out'));
    await tester.tap(find.byTooltip('Zoom out')); // never below the whole frame
    await tester.pump();
    expect(scaleOf(tester), 1);
  });
}
