// Run explicitly to refresh documentation screenshots; not a golden comparison.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/live/live_controller.dart';
import 'package:shuttlesense_app/features/live/widgets/live_coach_panel.dart';
import 'package:shuttlesense_app/features/results/widgets/scoreboard.dart';
import 'package:shuttlesense_app/shared/widgets/courtside_tools.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets('documentation preview $width', (tester) async {
      final root = Platform.environment['FLUTTER_ROOT']!;
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(
            ByteData.sublistView(
              File('$root/bin/cache/artifacts/material_fonts/roboto-regular.ttf').readAsBytesSync(),
            ),
          ),
        );
      await loader.load();
      await (FontLoader('MaterialIcons')..addFont(
            Future.value(
              ByteData.sublistView(
                File(
                  '$root/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
                ).readAsBytesSync(),
              ),
            ),
          ))
          .load();
      tester.view.physicalSize = Size(width, width == 360 ? 1550 : 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final record = ClipRecord.fromJson({
        'schema_version': '1.6',
        'clip_id': 'preview',
        'fps': 30,
        'width': 640,
        'height': 360,
        'num_frames': 300,
        'frames': [],
        'hits': [],
        'score': {
          'near': 11,
          'far': 8,
          'server': 'near',
          'service_court': 'left',
          'interval': true,
          'interval_s': 60,
        },
        'decision_log': [
          {
            'id': 1,
            'kind': 'award',
            'detail': 'Point awarded to Near',
            'game': 1,
            'frame': 200,
            'at': '2026-11-15T09:00:00Z',
            'score': {'near': 11, 'far': 8},
          },
        ],
      });
      final boundary = GlobalKey();
      final referee = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Referee', style: AppTheme.light().textTheme.headlineSmall),
          Scoreboard(
            record: record,
            frameIndex: 299,
            live: true,
            showHistory: false,
            onAward: (_) {},
            onUndo: () {},
          ),
          IntervalPanel(
            interval: IntervalState.fromJson({
              'key': 'preview',
              'status': 'paused',
              'remaining_s': 42,
              'duration_s': 60,
            }),
            onAction: (_) {},
          ),
          DecisionHistory(record: record),
        ],
      );
      final coach = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Coach', style: AppTheme.light().textTheme.headlineSmall),
          LiveCoachPanel(
            player: 'near',
            onPlayerChanged: (_) {},
            state: const LiveState(
              lastRally: RallySummary(
                index: 8,
                durationS: 5.6,
                strokes: 7,
                winner: 'near',
                faults: [
                  (
                    hitId: 1,
                    player: 'near',
                    hitter: null,
                    stroke: 'smash',
                    tip: 'Extend your hitting arm fully at contact.',
                  ),
                ],
              ),
            ),
            goalControls: PracticeGoalCard(
              goal: const PracticeGoal(
                text: 'Recover to the centre after each overhead stroke.',
                player: 'near',
              ),
              onComplete: (_) {},
              onEdit: () {},
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light().copyWith(
            textTheme: AppTheme.light().textTheme.apply(fontFamily: 'Roboto'),
          ),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              appBar: AppBar(
                title: const Text('ShuttleSense courtside', style: TextStyle(fontFamily: 'Roboto')),
              ),
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Synthetic preview · no camera or model measurements'),
                      const SizedBox(height: 24),
                      if (width == 360) ...[
                        referee,
                        const SizedBox(height: 24),
                        coach,
                      ] else
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: referee),
                            const SizedBox(width: 24),
                            Expanded(child: coach),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Decision history (1)'));
      // Let expansion finish without waiting for the live interval's periodic ticker.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final image = await (boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('../docs/media/courtside-${width.toInt()}.png');
        output.parent.createSync(recursive: true);
        output.writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    });
  }
}
