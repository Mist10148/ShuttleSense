// Phase 12 (T12.5, T12.6): scoreboard, minimap and referee decisions courtside.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/results/widgets/court_minimap.dart';
import 'package:shuttlesense_app/features/results/widgets/scoreboard.dart';
import 'package:shuttlesense_app/shared/widgets/game_service_prompt.dart';
import 'package:shuttlesense_app/shared/widgets/start_score_field.dart';

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

CourtPainter painter(ClipRecord record, int frame, {bool live = false, int? rallyStart}) =>
    CourtPainter.fromRecord(
      record,
      frame,
      lines: Colors.white,
      surface: Colors.green,
      players: AppTheme.playerColorsLight,
      live: live,
      rallyStart: rallyStart,
    );

/// The golden record (one rally, frames 0–55) as game 2 of a best of 3 the near side
/// leads after winning game 1 21–17.
ClipRecord secondGame() {
  final golden = goldenRecord();
  return golden.copyWith(
    rallies: [
      for (final r in golden.rallies)
        Rally(
          index: r.index,
          startFrame: r.startFrame,
          endFrame: r.endFrame,
          strokeCount: r.strokeCount,
          landing: r.landing,
          winner: r.winner,
          scoreAfter: r.scoreAfter,
          game: 2,
        ),
    ],
    score: const Score(
      near: 1,
      far: 0,
      bestOf: 3,
      game: 2,
      games: [ScorePair(near: 21, far: 17)],
      gamesWon: ScorePair(near: 1, far: 0),
      server: 'near',
      serviceCourt: 'left',
    ),
  );
}

void main() {
  group('Minimap hit marks', () {
    test('live: only the open rally, none between rallies', () {
      final record = goldenRecord();
      expect(painter(record, 59, live: true).hitMarks, isEmpty);
      final open = painter(record, 59, live: true, rallyStart: 20);
      expect(open.hitMarks.map((m) => m.$1), ['far', 'near']);
    });

    test('offline between rallies: no marks from the rally before', () {
      expect(painter(goldenRecord(), 58).hitMarks, isEmpty);
      expect(painter(goldenRecord(), 50).hitMarks, hasLength(3));
    });
  });

  group('Scoreboard', () {
    testWidgets('finished games keep their scores', (tester) async {
      await pump(tester, Scoreboard(record: secondGame(), frameIndex: 58));
      expect(find.text('G1 21–17'), findsOneWidget);
      expect(find.text('Game 2 of 3 · games 1–0'), findsOneWidget);
    });

    testWidgets('the game header follows a scrub back into an earlier game', (tester) async {
      final record = secondGame();
      final score = record.score!;
      // The rally is now from game 1, and the match has moved on to game 2.
      final scrubbed = record.copyWith(
        rallies: [
          for (final r in record.rallies)
            Rally(
              index: r.index,
              startFrame: r.startFrame,
              endFrame: r.endFrame + 4,
              strokeCount: r.strokeCount,
              winner: r.winner,
              scoreAfter: r.scoreAfter,
            ),
        ],
        score: score,
      );
      await pump(tester, Scoreboard(record: scrubbed, frameIndex: 20));
      expect(find.text('Game 1 of 3 · games 0–0'), findsOneWidget);
    });

    testWidgets('a mid-match start numbers the games from where it joined', (tester) async {
      final record = secondGame().copyWith(
        score: const Score(
          near: 0,
          far: 0,
          bestOf: 3,
          game: 3,
          games: [ScorePair(near: 21, far: 19)],
          gamesWon: ScorePair(near: 1, far: 1),
          startGames: ScorePair(near: 0, far: 1),
          interval: true,
          changeEnds: true,
          intervalSeconds: 120,
        ),
      );
      await pump(tester, Scoreboard(record: record, frameIndex: 58));
      expect(find.text('G2 21–19'), findsOneWidget);
      expect(find.text('Interval (120 s): change ends'), findsOneWidget);
    });

    testWidgets('the doubles service picker shows for a doubles job the record cannot tell', (
      tester,
    ) async {
      // A singles-looking record (no partners seen) in game 2 with no service slots.
      final record = secondGame();
      expect(record.isDoubles, isFalse);
      Widget board({required bool doubles}) =>
          Scoreboard(record: record, frameIndex: 58, doubles: doubles, onSetService: (_, _, _) {});
      await pump(tester, board(doubles: false));
      expect(find.byType(GameServicePrompt), findsNothing);
      await pump(tester, board(doubles: true));
      expect(find.byType(GameServicePrompt), findsOneWidget);
    });

    testWidgets('a let reads as a let, not as a rally to decide', (tester) async {
      final golden = goldenRecord();
      final record = golden.copyWith(
        rallies: [
          for (final r in golden.rallies)
            Rally(index: r.index, startFrame: r.startFrame, endFrame: r.endFrame),
        ],
        score: const Score(
          near: 0,
          far: 0,
          corrections: [ScoreCorrection(rallyIndex: 0, winnerBefore: 'near', reason: 'let')],
        ),
      );
      await pump(tester, Scoreboard(record: record, frameIndex: 58));
      expect(find.widgetWithText(Chip, 'Let'), findsOneWidget);
      expect(find.byTooltip('Undecided: pick the winner'), findsNothing);
    });

    testWidgets('the decision menu gives faults, a let and a confirmed retirement', (tester) async {
      final awards = <(String, String)>[];
      final conceded = <String>[];
      var lets = 0;
      await pump(
        tester,
        Scoreboard(
          record: goldenRecord(),
          frameIndex: 58,
          onAward: (_) {},
          onUndo: () {},
          onAwardReason: (side, reason) => awards.add((side, reason)),
          onLet: () => lets++,
          onConcede: conceded.add,
        ),
      );
      Future<void> pick(String item) async {
        await tester.tap(find.byKey(const Key('decision-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(item).last);
        await tester.pumpAndSettle();
      }

      await pick('Service fault by Near (point Far)');
      await pick('Fault by Far (point Near)');
      await pick('Let: replay the last rally');
      expect(awards, [('far', 'service_fault'), ('near', 'fault')]);
      expect(lets, 1);
      await pick('Far retires');
      expect(find.text('Far retires?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(conceded, isEmpty);
      await pick('Far retires');
      await tester.tap(find.widgetWithText(FilledButton, 'Retire'));
      await tester.pumpAndSettle();
      expect(conceded, ['near']);
    });

    testWidgets('a retired match says so and closes the decision menu', (tester) async {
      final record = goldenRecord().copyWith(
        score: const Score(
          near: 3,
          far: 1,
          matchWinner: 'far',
          corrections: [ScoreCorrection(rallyIndex: 1, winnerAfter: 'far', kind: 'concede')],
        ),
      );
      await pump(
        tester,
        Scoreboard(record: record, frameIndex: 58, onAward: (_) {}, onConcede: (_) {}),
      );
      expect(find.text('Far wins (retired)'), findsOneWidget);
      final menu = tester.widget<PopupMenuButton<String>>(find.byKey(const Key('decision-menu')));
      expect(menu.enabled, isFalse);
    });
  });

  group('Models', () {
    test('clip record 1.5 fields parse, and older ones default', () {
      final score = Score.fromJson({
        'near': 0,
        'far': 0,
        'start_games': {'near': 1, 'far': 0},
        'interval_s': 120,
        'game_service': [
          {'game': 2, 'server_id': 'far_2', 'receiver_id': 'near_1'},
        ],
        'corrections': [
          {
            'rally_index': 3,
            'winner_before': 'near',
            'winner_after': null,
            'kind': 'winner',
            'reason': 'let',
          },
          {'rally_index': 4, 'winner_before': null, 'winner_after': 'far', 'kind': 'concede'},
        ],
      });
      expect(score.firstGame, 2);
      expect(score.intervalSeconds, 120);
      expect(score.gameService.single.serverId, 'far_2');
      expect(score.corrections.first.isLet, isTrue);
      expect(score.conceded, isTrue);
      final old = Score.fromJson({'near': 2, 'far': 1});
      expect((old.firstGame, old.intervalSeconds, old.conceded), (1, null, false));
    });

    test('an undo reply carries the line calls back', () {
      final json = goldenRecordJson();
      final update = ScoreUpdate.fromJson({
        'score': {'near': 0, 'far': 0},
        'rallies': json['rallies'],
        'line_calls': json['line_calls'],
      });
      expect(update.lineCalls, isNotNull);
      expect(ScoreUpdate.fromJson({'score': json['score'], 'rallies': []}).lineCalls, isNull);
    });

    test('decision menu needs a 1.5 backend', () {
      Health health(String schema) => Health.fromJson({
        'version': '0.1.0',
        'schema_version': schema,
        'device': 'cpu',
        'auth_required': false,
        'stages': <String>[],
      });
      expect(health('1.4').supportsCourtside, isFalse);
      expect(health('1.5').supportsCourtside, isTrue);
    });
  });

  testWidgets('games already won report null at 0–0 and name the game', (tester) async {
    ({int near, int far})? value = (near: 0, far: 1);
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) =>
            StartGamesField(value: value, onChanged: (v) => setState(() => value = v)),
      ),
    );
    expect(find.text('Games already won (starts in game 2 of 3)'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('start-games-Far player')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('0').last);
    await tester.pumpAndSettle();
    expect(value, isNull);
  });
}
