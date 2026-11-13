// Four players in the results views (Phase 9, T9.11), from the doubles golden record.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/results/widgets/court_minimap.dart';
import 'package:shuttlesense_app/features/results/widgets/scoreboard.dart';
import 'package:shuttlesense_app/features/results/widgets/stroke_timeline.dart';
import 'package:shuttlesense_app/features/results/widgets/summary_chart.dart';

import 'minimap_test.dart' show contrast;

ClipRecord doublesRecord() => ClipRecord.fromJson(
  jsonDecode(File('test/fixtures/golden_record_doubles.json').readAsStringSync())
      as Map<String, dynamic>,
);

Future<void> pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(500, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('player labels name the doubles slots', () {
    expect(['near', 'far', 'near_1', 'near_2', 'far_1', 'far_2'].map(playerLabel), [
      'Near',
      'Far',
      'Near 1',
      'Near 2',
      'Far 1',
      'Far 2',
    ]);
    expect(doublesRecord().isDoubles, isTrue);
  });

  for (final (name, theme, players) in [
    ('light', AppTheme.light(), AppTheme.playerColorsLight),
    ('dark', AppTheme.dark(), AppTheme.playerColorsDark),
  ]) {
    test('$name theme: partner marks stand out from the court and differ from the side', () {
      final surface = theme.colorScheme.surfaceContainerHighest;
      expect(contrast(players.near2, surface), greaterThanOrEqualTo(3));
      expect(contrast(players.far2, surface), greaterThanOrEqualTo(3));
      expect(players.forPlayer('near_2'), players.near2);
      expect(players.forPlayer('near_1'), players.near);
      expect(players.forPlayer('far'), players.far);
      expect(players.near2, isNot(players.near));
    });
  }

  test('the minimap reads out all four players in doubles', () {
    final label = minimapLabel(doublesRecord(), 10);
    expect(label, startsWith('Top-down doubles court. Near player 1 at '));
    expect(label, contains('Near player 2 at '));
    expect(label, contains('Far player 2 at '));
  });

  testWidgets('the minimap draws a doubles court', (tester) async {
    await pump(tester, CourtMinimap(record: doublesRecord(), frameIndex: 10));
    final ratio = tester.widget<AspectRatio>(find.byType(AspectRatio)).aspectRatio;
    expect(ratio, closeTo((5.18 + 0.92) / 13.40, 1e-9));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the timeline names the partner who hit', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StrokeTimeline(hits: doublesRecord().hits, currentHitId: null, onSeek: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('N1'), findsOneWidget);
    expect(find.text('F1'), findsOneWidget);
    expect(find.text('N2'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('^Near 2 player, Smash')), findsOneWidget);
  });

  testWidgets('the scoreboard names who serves and receives', (tester) async {
    final record = doublesRecord();
    await pump(tester, Scoreboard(record: record, frameIndex: record.numFrames - 1));
    expect(find.text('Near 1 serves to Far 2'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && (w.properties.label ?? '').contains('Near 1 serves from the left'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the stroke chart shows each partner', (tester) async {
    await pump(tester, SummaryChart(summary: doublesRecord().summary));
    expect(find.textContaining('Near 2: 1 hits'), findsOneWidget);
    expect(find.textContaining('Far 2: 0 hits'), findsOneWidget);
    expect(find.textContaining('Near: '), findsNothing);
  });

  testWidgets('rally winner tooltips name the pair in doubles', (tester) async {
    final record = doublesRecord();
    await pump(tester, RallyHistory(record: record, frameIndex: 0, onCorrect: (_, _) {}));
    final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip));
    expect(chips, isNotEmpty);
    expect(chips.map((c) => c.tooltip ?? ''), everyElement(contains(' pair')));
  });

  test('the heatmap describes each pair in doubles', () {
    final text = HeatGrid.fromRecord(doublesRecord()).describe();
    expect(text, contains('near pair'));
    expect(text, contains('far pair'));
  });

  test('a doubles hit with no known partner is not marked as partner 1', () {
    final json =
        jsonDecode(File('test/fixtures/golden_record_doubles.json').readAsStringSync())
            as Map<String, dynamic>;
    final hits = json['hits'] as List;
    final first = (hits.first as Map<String, dynamic>)..remove('hitter');
    final record = ClipRecord.fromJson(json);
    final at = first['frame'] as int;
    final painter = CourtPainter.fromRecord(
      record,
      at,
      lines: Colors.white,
      surface: Colors.green,
      players: AppTheme.playerColorsLight,
    );
    expect(painter.hitMarks.where((m) => m.$1 == 'near'), isEmpty);
    final known = CourtPainter.fromRecord(
      doublesRecord(),
      at,
      lines: Colors.white,
      surface: Colors.green,
      players: AppTheme.playerColorsLight,
    );
    expect(known.hitMarks, isNotEmpty);
  });

  testWidgets('the stroke chart legend wraps in a narrow side panel', (tester) async {
    await pump(tester, SizedBox(width: 180, child: SummaryChart(summary: doublesRecord().summary)));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Near 2: 1 hits'), findsOneWidget);
  });

  testWidgets('after game 1 the scoreboard asks who serves first in game 2', (tester) async {
    const game2 = Score(
      near: 0,
      far: 0,
      bestOf: 3,
      game: 2,
      gamesWon: ScorePair(near: 0, far: 1),
      server: 'far',
      serviceCourt: 'right',
    );
    final record = doublesRecord().copyWith(score: game2);
    final set = <String>[];
    await pump(
      tester,
      Scoreboard(
        record: record,
        frameIndex: record.numFrames - 1,
        onSetService: (game, s, r) => set.add('$game $s $r'),
      ),
    );
    expect(find.text('Who serves first in game 2?'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String?>).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Far 2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String?>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Near 1').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set service'));
    expect(set, ['2 far_2 near_1']);
    // Named already, or a game-1 score: no prompt.
    await pump(
      tester,
      Scoreboard(
        record: doublesRecord(),
        frameIndex: record.numFrames - 1,
        onSetService: (_, _, _) {},
      ),
    );
    expect(find.textContaining('Who serves first'), findsNothing);
  });
}
