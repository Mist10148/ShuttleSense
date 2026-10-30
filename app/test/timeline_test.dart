import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/results/widgets/stroke_timeline.dart';

import 'fakes/fake_api_client.dart';

Future<List<Hit>> pumpTimeline(WidgetTester tester, {List<Hit>? hits, int? current}) async {
  final seeks = <Hit>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: StrokeTimeline(
          hits: hits ?? goldenRecord().hits,
          currentHitId: current,
          onSeek: seeks.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return seeks;
}

void main() {
  testWidgets('rows show stroke, confidence, estimated speed and the first tip', (tester) async {
    await pumpTimeline(tester);
    expect(find.text('Serve'), findsOneWidget);
    expect(find.text('Smash'), findsOneWidget);
    expect(find.textContaining('86% · ~241 km/h (est.)'), findsOneWidget);
    expect(find.textContaining('Fully extend your elbow'), findsOneWidget);
  });

  testWidgets('tap seeks half a second before the hit', (tester) async {
    final seeks = await pumpTimeline(tester);
    await tester.tap(find.text('Clear'));
    // Clear at frame 25 / 30 fps = 0.833 s; minus 0.5 s.
    expect(seekTarget(seeks.single), const Duration(microseconds: 333000));
    await tester.tap(find.text('Serve'));
    expect(seekTarget(seeks.last), Duration.zero); // never negative
  });

  testWidgets('player filter hides the other side', (tester) async {
    await pumpTimeline(tester);
    await tester.tap(find.text('Far'));
    await tester.pumpAndSettle();
    expect(find.text('Clear'), findsOneWidget);
    expect(find.text('Smash'), findsNothing);
  });

  testWidgets('stroke filter shows one class, then all again', (tester) async {
    await pumpTimeline(tester);
    await tester.tap(find.byTooltip('Filter by stroke'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Smash').last); // the menu item, above the row
    await tester.pumpAndSettle();
    expect(find.text('Serve'), findsNothing);
    expect(find.text('Clear'), findsNothing);
    expect(find.text('Smash'), findsNWidgets(2)); // the filter chip and the row

    await tester.tap(find.byTooltip('Filter by stroke'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All strokes').last);
    await tester.pumpAndSettle();
    expect(find.text('Serve'), findsOneWidget);
    expect(find.text('Clear'), findsOneWidget);
  });

  testWidgets('low confidence shows a question mark', (tester) async {
    await pumpTimeline(
      tester,
      hits: const [
        Hit(id: 0, frame: 3, timeS: 0.1, player: 'near', stroke: 'drop', confidence: 0.3),
      ],
    );
    expect(find.text('Drop ?'), findsOneWidget);
  });

  testWidgets('details sheet lists every rule with the disclaimer', (tester) async {
    await pumpTimeline(tester);
    await tester.longPress(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Form feedback'), findsOneWidget);
    expect(find.text('Clear contact above head'), findsOneWidget);
    expect(find.text('Clear arm extension'), findsOneWidget);
    expect(find.byIcon(Icons.cancel), findsOneWidget);
    expect(find.text('Heuristic guidance, not professional coaching.'), findsOneWidget);
  });
}
