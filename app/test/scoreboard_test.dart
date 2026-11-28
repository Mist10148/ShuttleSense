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
      // Past the last rally the match state shows too: the near player serves from the left
      // court on 1 point.
      expect(scoreLabel('Score: near 1, far 0. Near serves from the left court'), findsOneWidget);
      expect(find.text('Near serves · left court'), findsOneWidget);
      expect(find.textContaining('Rally 1 · 3 strokes · in'), findsOneWidget);
    });

    testWidgets('picking the other winner calls the correction', (tester) async {
      final calls = <(int, String?)>[];
      await pump(
        tester,
        Scoreboard(
          record: goldenRecord(),
          frameIndex: 58,
          onCorrect: (rally, winner) => calls.add((rally, winner)),
        ),
      );
      await tester.tap(find.widgetWithText(ChoiceChip, 'Near')); // already the winner: clear
      await tester.tap(find.widgetWithText(ChoiceChip, 'Far'));
      expect(calls, [(0, null), (0, 'far')]);
    });

    testWidgets('match state: games, game point, change of ends and the result', (tester) async {
      final record = goldenRecord().copyWith(
        score: const Score(
          near: 20,
          far: 11,
          bestOf: 3,
          game: 3,
          gamesWon: ScorePair(near: 1, far: 1),
          server: 'near',
          serviceCourt: 'right',
          gamePoint: ['near'],
          matchPoint: ['near'],
          changeEnds: true,
          interval: true,
        ),
      );
      await pump(tester, Scoreboard(record: record, frameIndex: 59, live: true));
      expect(find.text('Game 3 of 3 · games 1–1'), findsOneWidget);
      expect(find.text('Match point Near'), findsOneWidget);
      expect(find.text('Game point Near'), findsNothing); // the match point says it
      expect(find.text('Interval: change ends'), findsOneWidget);
      final won = goldenRecord().copyWith(
        score: const Score(near: 21, far: 15, bestOf: 3, matchWinner: 'far'),
      );
      await pump(tester, Scoreboard(record: won, frameIndex: 59, live: true));
      expect(find.text('Match won by Far'), findsOneWidget);
    });

    testWidgets('award and undo buttons', (tester) async {
      final awarded = <String>[];
      var undone = 0;
      final record = goldenRecord().copyWith(
        score: const Score(
          near: 1,
          far: 0,
          corrections: [ScoreCorrection(rallyIndex: 1, winnerAfter: 'near', kind: 'award')],
        ),
      );
      await pump(
        tester,
        Scoreboard(
          record: record,
          frameIndex: 59,
          live: true,
          onAward: awarded.add,
          onUndo: () => undone++,
        ),
      );
      await tester.tap(find.text('Point Far'));
      await tester.tap(find.text('Undo'));
      expect(awarded, ['far']);
      expect(undone, 1);
      expect(find.text('1 point(s) awarded'), findsOneWidget);
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

    testWidgets('a close call given to the likely side says why and asks for a check', (
      tester,
    ) async {
      final record = goldenRecord().copyWith(
        rallies: const [
          Rally(
            index: 0,
            startFrame: 0,
            endFrame: 55,
            winner: 'far',
            review: 'Close call: looks IN by 6 cm at the back line. Check it',
            landing: Landing(x: 1.2, y: 0.06, inCourt: true, confidence: 0.14),
          ),
          Rally(
            index: 1,
            startFrame: 60,
            endFrame: 90,
            review: 'Not called: no landing was seen. Pick the winner',
          ),
        ],
      );
      await pump(tester, Scoreboard(record: record, frameIndex: 95));
      expect(find.byKey(const Key('calls-to-check')), findsOneWidget);
      expect(find.text('2 calls to check'), findsOneWidget);
      expect(find.text('Close call: looks IN by 6 cm at the back line. Check it'), findsOneWidget);
      expect(find.byKey(const ValueKey('rally-review-1')), findsOneWidget);
      expect(find.byIcon(Icons.flag_outlined), findsOneWidget); // the close call
      expect(find.byIcon(Icons.help_outline), findsOneWidget); // the uncalled rally
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

  group('change of ends', () {
    Score score({bool swapped = true}) => Score(
      near: 3,
      far: 5,
      bestOf: 3,
      game: 2,
      games: const [ScorePair(near: 17, far: 21)],
      gamesWon: const ScorePair(near: 0, far: 1),
      autoChangeEnds: true,
      endsSwapped: swapped,
      corrections: const [
        ScoreCorrection(rallyIndex: 1, kind: 'ends', frame: 57),
        ScoreCorrection(rallyIndex: 1, winnerAfter: 'far', kind: 'award', frame: 58),
      ],
    );

    testWidgets('the board says the ends changed and counts the change', (tester) async {
      await pump(
        tester,
        Scoreboard(record: goldenRecord().copyWith(score: score()), frameIndex: 59),
      );
      expect(find.byKey(const Key('ends-changed')), findsOneWidget);
      expect(find.text('Game 2 of 3 · games 0–1'), findsOneWidget);
      expect(find.text('G1 17–21'), findsOneWidget);
      expect(find.textContaining('1 change(s) of ends'), findsOneWidget);
      expect(find.textContaining('1 point(s) awarded'), findsOneWidget);
      expect(find.textContaining('correction(s)'), findsNothing);

      await pump(
        tester,
        Scoreboard(record: goldenRecord().copyWith(score: score(swapped: false)), frameIndex: 59),
      );
      expect(find.byKey(const Key('ends-changed')), findsNothing);
    });

    testWidgets('earlier in the replay the totals are shown from the ends as they were', (
      tester,
    ) async {
      // The golden rally was played before the change: the game the far end now holds was
      // won from the near end.
      await pump(
        tester,
        Scoreboard(record: goldenRecord().copyWith(score: score()), frameIndex: 10),
      );
      expect(find.byKey(const Key('ends-changed')), findsNothing);
      expect(find.text('G1 21–17'), findsOneWidget);
    });

    testWidgets('Players changed ends is in the decision menu', (tester) async {
      var swaps = 0;
      await pump(
        tester,
        Scoreboard(
          record: goldenRecord().copyWith(score: score(swapped: false)),
          frameIndex: 59,
          onAward: (_) {},
          onSwapEnds: () => swaps++,
        ),
      );
      await tester.tap(find.byKey(const Key('decision-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Players changed ends'));
      await tester.pumpAndSettle();
      expect(swaps, 1);
      // Without the callback (an older server) the item is not offered.
      await pump(
        tester,
        Scoreboard(
          record: goldenRecord().copyWith(score: score(swapped: false)),
          frameIndex: 59,
          onAward: (_) {},
          onLet: () {},
        ),
      );
      await tester.tap(find.byKey(const Key('decision-menu')));
      await tester.pumpAndSettle();
      expect(find.text('Players changed ends'), findsNothing);
    });
  });
}
