import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/results/widgets/court_minimap.dart';
import 'package:shuttlesense_app/features/results/widgets/results_layout.dart';
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

  test('the heatmap adds up the time each player stood in each place', () {
    final record = recordWith(const [
      FrameInfo(frame: 0, nearPos: (x: 2.6, y: 1.9), farPos: (x: 2.4, y: 11.4)),
      FrameInfo(frame: 1, nearPos: (x: 2.7, y: 1.8)),
      FrameInfo(frame: 2, nearPos: (x: 0.2, y: 4.0)),
      FrameInfo(frame: 3, nearPos: (x: 40, y: 1)), // a glitch far off the court is dropped
    ]);
    final heat = HeatGrid.fromRecord(record);
    // Seconds: three frames at 30 fps for the near player, one for the far one.
    expect(heat.near.fold<double>(0, (a, b) => a + b), closeTo(3 / 30, 1e-9));
    expect(heat.far.fold<double>(0, (a, b) => a + b), closeTo(1 / 30, 1e-9));
    expect(
      heat.describe(),
      'Heatmap: near player mostly at 2.6 m across, 1.9 m up the court; '
      'far player mostly at 2.4 m across, 11.4 m up the court.',
    );
  });

  test('doubles alleys share the export grid origin and preserve player-seconds', () {
    final heat = HeatGrid.fromRecord(
      recordWith(const [
        FrameInfo(frame: 0, nearPos: (x: -0.3, y: 1), near2Pos: (x: 5.5, y: 1)),
        FrameInfo(frame: 1, farPos: (x: 2.6, y: 12)),
      ]),
    );
    expect(HeatGrid.cellOrigin(0), (x: -2.0, y: -2.0));
    expect(HeatGrid.cols, 37);
    expect(heat.near.fold<double>(0, (a, b) => a + b), closeTo(2 / 30, 1e-9));
    expect(heat.far.fold<double>(0, (a, b) => a + b), closeTo(1 / 30, 1e-9));
  });

  test('the heatmap kernel is in meters and wider far from the camera', () {
    expect(HeatGrid.sigmaAt(0), lessThan(HeatGrid.sigmaAt(kCourtLengthM)));
    final near = HeatGrid.fromRecord(
      recordWith(const [FrameInfo(frame: 0, nearPos: (x: 2.6, y: 1.0))]),
    );
    final far = HeatGrid.fromRecord(
      recordWith(const [FrameInfo(frame: 0, farPos: (x: 2.6, y: 12.4))]),
    );
    // The same 1/30 s spread wider: a lower peak far away.
    expect(near.nearMax, greaterThan(far.farMax));
    // Roughly 1 σ (0.3 m) from the peak cell the density has fallen, but not to nothing.
    final peak = near.near.indexOf(near.nearMax);
    expect(near.near[peak + 1] / near.nearMax, inExclusiveRange(0.5, 1.0));
    expect(near.near[peak + 4], lessThan(near.nearMax * 0.05));
  });

  test('the heatmap counts frames in play only, and shades around a busy place', () {
    const record = ClipRecord(
      schemaVersion: '1.7',
      clipId: 'c',
      fps: 30,
      width: 1280,
      height: 720,
      numFrames: 6,
      frames: [
        FrameInfo(frame: 0, nearPos: (x: 0.2, y: 0.2)), // waiting before the rally
        FrameInfo(frame: 1, nearPos: (x: 2.6, y: 1.9)),
        FrameInfo(frame: 2, nearPos: (x: 2.6, y: 1.9)),
        FrameInfo(frame: 3, nearPos: (x: 2.6, y: 1.9)),
        FrameInfo(frame: 4, nearPos: (x: 0.2, y: 0.2)), // and after it
        // Pinned at the 2 m clamp edge: the player was somewhere beyond it, so dropped.
        FrameInfo(frame: 5, nearPos: (x: 7.18, y: 15.4)),
      ],
      hits: [],
      rallies: [
        Rally(index: 0, startFrame: 1, endFrame: 3),
        Rally(index: 1, startFrame: 5, endFrame: 5),
      ],
      courtCorners: [(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1), (x: 0, y: 1)],
    );
    final heat = HeatGrid.fromRecord(record);
    expect(heat.near.fold<double>(0, (a, b) => a + b), closeTo(3 / 30, 1e-9));
    final busiest = heat.near.indexOf(heat.nearMax);
    final o = HeatGrid.cellOrigin(busiest);
    expect((o.x - 2.6).abs(), lessThanOrEqualTo(kHeatCellM));
    expect((o.y - 1.9).abs(), lessThanOrEqualTo(kHeatCellM));
    expect(heat.nearShade[busiest], 1.0);
    // The cells next to it are shaded less, and a cell far away not at all.
    expect(heat.nearShade[busiest + 1], inExclusiveRange(0.0, 1.0));
    expect(heat.nearShade[busiest + 8], 0.0);
    expect(heat.farShade.every((v) => v == 0), isTrue);
  });

  test('the shuttle is placed along the line from one hitter to the next', () {
    const hits = [
      Hit(id: 0, frame: 0, timeS: 0, player: 'near', rallyIndex: 0),
      Hit(id: 1, frame: 10, timeS: 0.33, player: 'far', rallyIndex: 0),
    ];
    final record = ClipRecord(
      schemaVersion: '1.7',
      clipId: 'c',
      fps: 30,
      width: 1280,
      height: 720,
      numFrames: 22,
      frames: [
        for (var i = 0; i <= 21; i++)
          FrameInfo(
            frame: i,
            nearPos: const (x: 1.0, y: 2.0),
            farPos: const (x: 4.0, y: 12.0),
            // The camera's floor mapping of a shuttle in the air: far beyond the court.
            shuttlePos: const (x: 2.0, y: 20.0),
          ),
      ],
      hits: hits,
      lineCalls: const [
        LineCall(
          id: 0,
          rallyIndex: 0,
          frame: 20,
          timeS: 0.67,
          call: 'in',
          landing: (x: 2.0, y: 1.0),
          marginCm: 30,
          confidence: 0.9,
          uncertain: false,
        ),
      ],
      courtCorners: const [(x: 0, y: 0), (x: 1, y: 0), (x: 1, y: 1), (x: 0, y: 1)],
    );
    final (mid, placed) = shuttleOverCourt(record, 5)!;
    expect(placed, isTrue);
    expect((mid.x, mid.y), (2.5, 7.0)); // halfway between the two players
    // After the last hit it flies to where it landed.
    final (late, _) = shuttleOverCourt(record, 15)!;
    expect((late.x, late.y), (3.0, 6.5));
    expect(shuttleOverCourt(record, 20), ((x: 2.0, y: 1.0), true));
    expect(shuttleOverCourt(record, 21), ((x: 2.0, y: 20.0), false));
    // With no hit before it, only the floor mapping is left, and it is marked as such.
    const early = ClipRecord(
      schemaVersion: '1.7',
      clipId: 'c',
      fps: 30,
      width: 1280,
      height: 720,
      numFrames: 1,
      frames: [FrameInfo(frame: 0, shuttlePos: (x: 2.0, y: 20.0))],
      hits: [],
    );
    expect(shuttleOverCourt(early, 0), ((x: 2.0, y: 20.0), false));
    expect(shuttleOverCourt(early, 3), isNull);
    // A frame where the shuttle was not seen draws nothing, even mid-flight.
    final unseen = ClipRecord(
      schemaVersion: '1.7',
      clipId: 'c',
      fps: 30,
      width: 1280,
      height: 720,
      numFrames: 21,
      frames: [
        for (final f in record.frames)
          f.frame == 5 ? const FrameInfo(frame: 5, nearPos: (x: 1.0, y: 2.0)) : f,
      ],
      hits: hits,
    );
    expect(shuttleOverCourt(unseen, 5), isNull);
  });

  test('the court picture keeps its shape and fits the room it is given', () {
    final aspect = courtViewAspect(doubles: false);
    // Room to spare: upright and as wide as the card.
    final (wide, wideOnSide) = courtViewLayout(300, 2000, doubles: false);
    expect(wideOnSide, isFalse);
    expect(wide.width, 300);
    expect(wide.height, closeTo(300 / aspect, 0.01));
    // A side panel shorter than the court: it shrinks to fit, same shape, still upright.
    final (short, shortOnSide) = courtViewLayout(368, 560, doubles: false);
    expect(shortOnSide, isFalse);
    expect(short.height, 460);
    expect(short.width / short.height, closeTo(aspect, 1e-9));
    // The tab under a phone's video is short and wide: the court lies on its side there.
    final (flat, flatOnSide) = courtViewLayout(304, 240, doubles: false);
    expect(flatOnSide, isTrue);
    expect(flat.height, 140);
    expect(flat.height / flat.width, closeTo(aspect, 1e-9));
    expect(flat.width, lessThanOrEqualTo(304));
    // Never wider than the card, whatever the room.
    expect(courtViewLayout(60, 150, doubles: true).$1.width, lessThanOrEqualTo(60));
  });

  for (final (name, size) in [('phone', phone), ('laptop', const Size(1280, 720))]) {
    testWidgets('$name: the whole court is on screen without scrolling', (tester) async {
      setSize(tester, size);
      final record = recordWith(const [
        // A far glitch and a player in the run-off: neither may paint outside the picture.
        FrameInfo(frame: 0, nearPos: (x: -1.9, y: -1.9), shuttlePos: (x: 2.0, y: 21.9)),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ResultsLayout(
              video: const AspectRatio(aspectRatio: 16 / 9, child: Placeholder()),
              status: const SizedBox(height: 40),
              timeline: const SizedBox.expand(),
              minimap: CourtMinimap(record: record, frameIndex: 0),
              scoreboard: const SizedBox(height: 200),
              coach: const SizedBox(height: 300),
            ),
          ),
        ),
      );
      if (find.text('Minimap').evaluate().isNotEmpty) {
        await tester.tap(find.text('Minimap'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Heatmap'));
      await tester.pump();
      final court = find.descendant(
        of: find.byType(CourtMinimap),
        matching: find.byType(CustomPaint),
      );
      final box = tester.getRect(court.last);
      final scroll = tester.getRect(
        find.ancestor(of: find.byType(CourtMinimap), matching: find.byType(SingleChildScrollView)),
      );
      expect(box.top, greaterThanOrEqualTo(scroll.top));
      expect(box.bottom, lessThanOrEqualTo(scroll.bottom));
      expect(box.shortestSide / box.longestSide, closeTo(courtViewAspect(doubles: false), 0.01));
      expect(box.longestSide, greaterThan(200));
      expect(find.ancestor(of: court.last, matching: find.byType(ClipRect)), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

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
    // The centre of the 0.25 m cell the player stands in.
    expect(find.bySemanticsLabel(RegExp('near player mostly at 2.6 m across')), findsOneWidget);
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
