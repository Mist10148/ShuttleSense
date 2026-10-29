import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/calibration/calibration_screen.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

void main() {
  test('isConvex mirrors the backend check', () {
    const court = [
      (x: 212.0, y: 650.0),
      (x: 1068.0, y: 650.0),
      (x: 880.0, y: 210.0),
      (x: 400.0, y: 210.0),
    ];
    expect(isConvex(court), isTrue);
    expect(isConvex(court.reversed.toList()), isTrue); // either winding
    final crossed = [court[0], court[2], court[1], court[3]];
    expect(isConvex(crossed), isFalse);
    expect(isConvex(court.take(3).toList()), isFalse);
  });

  Future<void> tapCorner(WidgetTester tester, Offset canvasFraction) async {
    final canvas = tester.getRect(find.byType(Image));
    await tester.tapAt(
      canvas.topLeft + Offset(canvas.width * canvasFraction.dx, canvas.height * canvasFraction.dy),
    );
    await tester.pumpAndSettle();
  }

  ButtonStyleButton startButton(WidgetTester tester) => tester.widget<ButtonStyleButton>(
    find.ancestor(of: find.text('Start processing'), matching: find.bySubtype<ButtonStyleButton>()),
  );

  testWidgets('4 taps in order enable the button; crossing order shows an error', (tester) async {
    final api = FakeApiClient();
    await pumpScreen(
      tester,
      const CalibrationScreen(videoId: 'vid1'),
      api: api,
      size: laptop,
    );
    expect(find.textContaining('Near left'), findsWidgets);
    await tapCorner(tester, const Offset(0.2, 0.9));
    await tapCorner(tester, const Offset(0.8, 0.9));
    await tapCorner(tester, const Offset(0.65, 0.3));
    expect(startButton(tester).onPressed, isNull);
    await tapCorner(tester, const Offset(0.35, 0.3));
    expect(startButton(tester).onPressed, isNotNull);

    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    await tapCorner(tester, const Offset(0.7, 0.95)); // crosses the near side
    expect(find.textContaining('The corners cross over'), findsOneWidget);
    expect(startButton(tester).onPressed, isNull);
  });

  testWidgets('dragging a handle moves a corner', (tester) async {
    await pumpScreen(tester, const CalibrationScreen(videoId: 'vid1'), size: laptop);
    await tapCorner(tester, const Offset(0.2, 0.9));
    final before = tester.getCenter(find.byKey(const ValueKey('corner-0')));
    await tester.drag(find.byKey(const ValueKey('corner-0')), const Offset(40, -20));
    await tester.pumpAndSettle();
    final after = tester.getCenter(find.byKey(const ValueKey('corner-0')));
    expect(after.dx, greaterThan(before.dx + 20));
    expect(after.dy, lessThan(before.dy - 5));
  });
}
