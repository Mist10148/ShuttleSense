import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/results/widgets/court_minimap.dart';
import 'package:shuttlesense_app/features/results/widgets/scoreboard.dart';

import 'fakes/fake_api_client.dart';

Future<void> pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

Finder scoreLabel(String label) =>
    find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label);

void main() {
  group('Scoreboard', () {
    testWidgets('score follows playback', (tester) async {
      final record = goldenRecord();
      await pump(tester, Scoreboard(record: record, frameIndex: 10));
      expect(scoreLabel('Score: near 0, far 0'), findsOneWidget);
      await pump(tester, Scoreboard(record: record, frameIndex: 58));
      expect(scoreLabel('Score: near 1, far 0'), findsOneWidget);
      expect(find.textContaining('Rally 1 · 3 strokes · in'), findsOneWidget);
    });

    testWidgets('picking the other winner calls the correction', (tester) async {
      final calls = <(int, String)>[];
      await pump(
        tester,
        Scoreboard(
          record: goldenRecord(),
          frameIndex: 58,
          onCorrect: (rally, winner) => calls.add((rally, winner)),
        ),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Near')); // already the winner
      await tester.tap(find.widgetWithText(ChoiceChip, 'Far'));
      expect(calls, [(0, 'far')]);
    });

    testWidgets('uncertain rallies ask the user', (tester) async {
      final record = goldenRecord().copyWith(
        rallies: const [
          Rally(
            index: 0,
            startFrame: 0,
            endFrame: 55,
            landing: Landing(x: 5.1, y: 10, inCourt: true, confidence: 0.2),
          ),
        ],
      );
      await pump(tester, Scoreboard(record: record, frameIndex: 58));
      expect(find.byIcon(Icons.help_outline), findsOneWidget);
      expect(find.textContaining('in ?'), findsOneWidget);
    });

    testWidgets('no referee shows a hint', (tester) async {
      final json = goldenRecordJson()..['score'] = null;
      await pump(tester, Scoreboard(record: ClipRecord.fromJson(json), frameIndex: 0));
      expect(find.text('Enable the referee layer to keep score.'), findsOneWidget);
    });
  });

  group('Minimap', () {
    test('painter repaints only when the frame changes', () {
      final record = goldenRecord();
      CourtPainter at(int i) => CourtPainter.fromRecord(
        record,
        i,
        lines: Colors.white,
        surface: Colors.green,
        players: AppTheme.playerColorsLight,
      );
      expect(at(10).shouldRepaint(at(10)), isFalse);
      expect(at(11).shouldRepaint(at(10)), isTrue);
    });

    test('trail holds the last 15 visible shuttle positions and hits of this rally', () {
      final painter = CourtPainter.fromRecord(
        goldenRecord(),
        50,
        lines: Colors.white,
        surface: Colors.green,
        players: AppTheme.playerColorsLight,
      );
      expect(painter.trail, hasLength(kTrailLength));
      expect(painter.hitMarks.map((m) => m.$1), ['near', 'far', 'near']);
      final gap = CourtPainter.fromRecord(
        goldenRecord(),
        33,
        lines: Colors.white,
        surface: Colors.green,
        players: AppTheme.playerColorsLight,
      );
      expect(gap.trail, hasLength(kTrailLength - 2)); // frames 31 and 32 have no shuttle
    });

    testWidgets('renders with a golden record frame', (tester) async {
      await pump(tester, CourtMinimap(record: goldenRecord(), frameIndex: 20));
      expect(find.byType(CustomPaint), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
