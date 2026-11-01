import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/results/widgets/court_minimap.dart';
import 'package:shuttlesense_app/features/results/widgets/video_panel.dart';

import 'helpers.dart';

/// WCAG contrast ratio between two colours.
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}

ClipRecord recordWith(List<FrameInfo> frames) => ClipRecord(
  schemaVersion: '1.1',
  clipId: 'c',
  fps: 30,
  width: 1280,
  height: 720,
  numFrames: frames.length,
  frames: frames,
  hits: const [],
  courtCorners: const [(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1), (x: 0, y: 1)],
);

void main() {
  test('the minimap reads out where the players and the shuttle are', () {
    final record = recordWith(const [
      FrameInfo(frame: 0, nearPos: (x: 2.6, y: 1.94), farPos: (x: 2.4, y: 11.4)),
    ]);
    expect(
      minimapLabel(record, 0),
      'Top-down court. Near player at 2.6 m across, 1.9 m up the court. '
      'Far player at 2.4 m across, 11.4 m up the court. Shuttle not seen.',
    );
    expect(minimapLabel(record, 5), contains('no positions'));
  });

  test('the heatmap counts where each player stood', () {
    final record = recordWith(const [
      FrameInfo(frame: 0, nearPos: (x: 2.6, y: 1.9), farPos: (x: 2.4, y: 11.4)),
      FrameInfo(frame: 1, nearPos: (x: 2.7, y: 1.8)),
      FrameInfo(frame: 2, nearPos: (x: 0.2, y: 4.0)),
      FrameInfo(frame: 3, nearPos: (x: 40, y: 1)), // a glitch far off the court is dropped
    ]);
    final heat = HeatGrid.fromRecord(record);
    expect(heat.near.fold<int>(0, (a, b) => a + b), 3);
    expect((heat.nearMax, heat.farMax), (2, 1));
    expect(
      heat.describe(),
      'Heatmap: near player mostly at 2.8 m across, 1.8 m up the court; '
      'far player mostly at 2.3 m across, 11.3 m up the court.',
    );
  });

  testWidgets('the heatmap toggle adds where players stood to the label', (tester) async {
    final handle = tester.ensureSemantics();
    final record = recordWith(const [FrameInfo(frame: 0, nearPos: (x: 2.6, y: 1.9))]);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(child: CourtMinimap(record: record, frameIndex: 0)),
        ),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('Heatmap: ')), findsNothing);
    await tester.tap(find.text('Heatmap'));
    await tester.pump();
    expect(find.bySemanticsLabel(RegExp('near player mostly at 2.8 m across')), findsOneWidget);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('the minimap label follows the frame', (tester) async {
    final handle = tester.ensureSemantics();
    final record = recordWith(const [
      FrameInfo(frame: 0, shuttlePos: (x: 1.0, y: 6.0)),
      FrameInfo(frame: 1, shuttlePos: (x: 3.0, y: 8.0)),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: CourtMinimap(record: record, frameIndex: 1)),
        ),
      ),
    );
    expect(find.bySemanticsLabel(RegExp('Shuttle at 3.0 m across, 8.0 m up')), findsOneWidget);
    handle.dispose();
  });

  for (final (name, theme, players) in [
    ('light', AppTheme.light(), AppTheme.playerColorsLight),
    ('dark', AppTheme.dark(), AppTheme.playerColorsDark),
  ]) {
    test('$name theme: player marks stand out from the court (3:1, T4.11)', () {
      final surface = theme.colorScheme.surfaceContainerHighest;
      expect(contrast(players.near, surface), greaterThanOrEqualTo(3));
      expect(contrast(players.far, surface), greaterThanOrEqualTo(3));
      // Court lines, and the ring drawn around the newest shuttle position.
      expect(contrast(theme.colorScheme.outline, surface), greaterThanOrEqualTo(3));
    });
  }

  testWidgets('a job without a video says so instead of showing a player (T4.6)', (tester) async {
    setSize(tester, phone);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VideoPanel(controller: null, available: false))),
    );
    expect(find.text('Annotated video not available'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VideoPanel(controller: null, available: null))),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Annotated video not available'), findsNothing);
  });
}
