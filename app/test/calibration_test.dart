import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/models/job.dart';
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

  testWidgets('tapping a corner handle does not add a corner', (tester) async {
    await pumpScreen(tester, const CalibrationScreen(videoId: 'vid1'), size: laptop);
    await tapCorner(tester, const Offset(0.2, 0.9));
    await tester.tap(find.byKey(const ValueKey('corner-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('corner-1')), findsNothing);
    await tapCorner(tester, const Offset(0.8, 0.9));
    expect(find.byKey(const ValueKey('corner-1')), findsOneWidget);
  });

  testWidgets('on a phone the frame and button fit, and Reset clears the corners', (tester) async {
    await pumpScreen(tester, const CalibrationScreen(videoId: 'vid1'));
    expect(tester.takeException(), isNull);
    expect(find.text('Start processing'), findsOneWidget);
    await tapCorner(tester, const Offset(0.2, 0.9));
    await tapCorner(tester, const Offset(0.8, 0.9));
    expect(find.byKey(const ValueKey('corner-1')), findsOneWidget);
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('corner-0')), findsNothing);
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

  testWidgets('skip sends no court overlays and no referee layer', (tester) async {
    final api = FakeApiClient();
    JobOptions? sent;
    api.onCreateJob = (options) => sent = options;
    await pumpScreen(
      tester,
      const CalibrationScreen(videoId: 'vid1'),
      api: api,
      size: laptop,
      prefs: {
        'options.overlays': ['trail', 'court', 'minimap', 'score'],
        'options.calibrate': true,
        'options.referee': true,
      },
    );
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(sent?.overlays, {'trail'});
    expect(sent?.referee, isFalse);
  });

  test('submittable keeps only overlays the server can draw', () {
    const options = JobOptions(overlays: {'trail', 'strokes', 'score'}, referee: false);
    const health = Health(
      version: '1',
      schemaVersion: '1.1',
      device: 'cpu',
      authRequired: false,
      stages: ['io', 'tracking', 'render'],
    );
    expect(options.submittable(health).overlays, {'trail'});
    expect(options.submittable(null).overlays, {'trail', 'strokes'});
  });
}
