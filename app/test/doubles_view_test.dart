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
}
