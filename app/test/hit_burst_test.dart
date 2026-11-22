// The comic burst that pops over the video when a player hits the shuttle.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/results/widgets/hit_anchor.dart';
import 'package:shuttlesense_app/shared/widgets/hit_burst.dart';

Future<void> pumpLayer(WidgetTester tester, List<HitBurstEvent> events, {double? nowS}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 360,
            child: HitBurstLayer(events: events, nowS: nowS),
          ),
        ),
      ),
    );

/// The burst on screen, if one is playing.
HitBurstPainter? burst(WidgetTester tester) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.descendant(of: find.byType(HitBurstLayer), matching: find.byType(CustomPaint)),
  )) {
    if (paint.painter case final HitBurstPainter p) return p;
  }
  return null;
}

void main() {
  test('each stroke has its word, and an unnamed hit is a plain HIT!', () {
    expect(hitBurstWord('smash'), 'SMASH!');
    expect(hitBurstWord('clear'), 'POW!');
    expect(hitBurstWord(null), 'HIT!');
    expect(hitBurstWord('something new'), 'HIT!');
    for (final stroke in kStrokeLabels.keys) {
      expect(hitBurstWord(stroke), isNot('HIT!'), reason: stroke);
    }
  });

  testWidgets('a hit pops once, in the colour of the hitter, and is gone after its time', (
    tester,
  ) async {
    const smash = HitBurstEvent(id: 1, who: 'near', stroke: 'smash', at: Offset(0.4, 0.5));
    await pumpLayer(tester, const []);
    expect(burst(tester), isNull);

    await pumpLayer(tester, const [smash]);
    await tester.pump(const Duration(milliseconds: 100));
    final shown = burst(tester)!;
    expect(shown.word, 'SMASH!');
    expect(shown.at, const Offset(0.4, 0.5));
    expect(shown.accent, AppTheme.playerColorsLight.near);

    await tester.pump(kHitBurstDuration);
    expect(burst(tester), isNull);
    // The same hit again (a rebuild, or a server that repeats its events) does not replay.
    await pumpLayer(tester, const [smash]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester), isNull);

    // The next hit does, and so does the first one after it left and came back (a seek).
    await pumpLayer(tester, const [HitBurstEvent(id: 2, who: 'far')]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)!.word, 'HIT!');
    expect(burst(tester)!.at.dy, lessThan(0.5)); // no position: the far half of the picture
    await tester.pump(kHitBurstDuration);
    await pumpLayer(tester, const [smash]);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)!.word, 'SMASH!');
    await tester.pump(kHitBurstDuration);
  });

  testWidgets('with a clock, a hit waits for its moment and a long-past one is skipped', (
    tester,
  ) async {
    const events = [
      HitBurstEvent(id: 0, who: 'near', stroke: 'serve', timeS: 1.0),
      HitBurstEvent(id: 1, who: 'far', stroke: 'clear', timeS: 6.0),
    ];
    await pumpLayer(tester, events, nowS: 5.0); // the serve is four seconds old
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester), isNull);
    await pumpLayer(tester, events, nowS: 5.9);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester), isNull);
    await pumpLayer(tester, events, nowS: 6.05);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)!.word, 'POW!');
    await tester.pump(kHitBurstDuration);

    // A new session counts its hits from 0 again: the same id at another time is new.
    await pumpLayer(tester, const [
      HitBurstEvent(id: 0, who: 'near', stroke: 'drop', timeS: 7.0),
      HitBurstEvent(id: 1, who: 'far', stroke: 'clear', timeS: 6.0),
    ], nowS: 7.1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)!.word, 'DROP!');
    await tester.pump(kHitBurstDuration);
  });

  testWidgets('rapid detected hits each get a turn, and a rewind resets playback', (tester) async {
    const hits = [
      HitBurstEvent(id: 10, who: 'near', stroke: 'smash', timeS: 1),
      HitBurstEvent(id: 11, who: 'far', stroke: 'drop', timeS: 1.05),
      HitBurstEvent(id: 11, who: 'far', stroke: 'drop', timeS: 1.05),
    ];
    await pumpLayer(tester, hits, nowS: 1.08);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)?.word, 'SMASH!');

    await tester.pump(kHitBurstDuration);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)?.word, 'DROP!');
    await tester.pump(kHitBurstDuration);
    expect(burst(tester), isNull);

    await pumpLayer(tester, hits, nowS: 0.9);
    expect(burst(tester), isNull);
    await pumpLayer(tester, hits, nowS: 1.01);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)?.word, 'SMASH!');
    await tester.pump(kHitBurstDuration);
  });

  testWidgets('the live feed supplies batched hits without replaying an old batch', (tester) async {
    final hits = [
      const HitBurstEvent(id: 0, who: 'near', stroke: 'serve'),
      const HitBurstEvent(id: 1, who: 'far', stroke: 'lift'),
    ];
    Future<void> live({required bool mounted, String session = 'session A'}) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: HitBurstFeed(
          session: session,
          count: hits.length,
          keyAt: (index) => hits[index].id,
          eventAt: (index) => hits[index],
          child: mounted ? const HitBurstLayer(events: []) : const SizedBox.expand(),
        ),
      ),
    );

    await live(mounted: true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)?.word, 'SERVE!');
    await tester.pump(kHitBurstDuration);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)?.word, 'WHOOSH!');
    await tester.pump(kHitBurstDuration);

    hits.insert(1, const HitBurstEvent(id: 2, who: 'near', stroke: 'smash'));
    await live(mounted: true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)?.word, 'SMASH!');
    await tester.pump(kHitBurstDuration);

    await live(mounted: false);
    await live(mounted: true);
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester), isNull);
    await live(mounted: true, session: 'session B');
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)?.word, 'SERVE!');
    await tester.pumpAndSettle();
  });

  testWidgets('reduced motion keeps the burst still', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: HitBurstLayer(events: [HitBurstEvent(id: 1, who: 'near')]),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(burst(tester)?.still, isTrue);
    await tester.pump(kHitBurstDuration);
  });

  test('a Watch hit event is placed at the top of the box of the hitter', () {
    final frame = <String, dynamic>{
      'players': {
        'near': {
          'bbox': [100, 200, 80, 240],
        },
      },
    };
    final event = HitBurstEvent.fromJson(
      {'id': 3, 'player': 'near', 'stroke': 'smash', 'time_s': 2.5},
      frame: frame,
      frameWidth: 1280,
      frameHeight: 720,
    )!;
    expect(event.id, 3);
    expect(event.who, 'near');
    expect(event.timeS, 2.5);
    expect(event.at!.dx, closeTo(140 / 1280, 1e-9));
    expect(event.at!.dy, closeTo(200 / 720, 1e-9));
    // A hitter the frame does not show: no position, and no crash on odd data.
    final far = HitBurstEvent.fromJson({'id': 4, 'player': 'far'}, frame: frame)!;
    expect(far.at, isNull);
    expect(HitBurstEvent.fromJson({'stroke': 'lift'}), isNull); // nothing to tell it apart by
    final layer = HitBurstLayer.watch(
      hits: {
        3: {'id': 3, 'player': 'near'},
        null: {'stroke': 'lift'},
      },
    );
    expect(layer.events.map((e) => e.id), [3]);
  });

  test('a recorded hit is placed where the shuttle was, else above the feet of the hitter', () {
    // Corners of a court seen straight on: the picture is the court, y flipped.
    ClipRecord record(FrameInfo frame) => ClipRecord(
      schemaVersion: '1.7',
      clipId: 'c',
      fps: 30,
      width: 518,
      height: 1340,
      numFrames: 1,
      frames: [frame],
      hits: const [Hit(id: 0, frame: 0, timeS: 0, player: 'near', stroke: 'smash')],
      courtCorners: const [(x: 0, y: 1340), (x: 518, y: 1340), (x: 518, y: 0), (x: 0, y: 0)],
    );
    final seen = record(
      const FrameInfo(frame: 0, nearPos: (x: 2.59, y: 3.35), shuttlePos: (x: 1.295, y: 6.7)),
    );
    final tracked = record(
      FrameInfo.fromJson({
        'frame': 0,
        'shuttle': {'visible': 1, 'x': 155.4, 'y': 603},
      }),
    );
    final trackedAt = hitAnchor(tracked, tracked.hits.single)!;
    expect(trackedAt.dx, closeTo(0.3, 1e-6));
    expect(trackedAt.dy, closeTo(0.45, 1e-6));
    final measuredPlayer = record(
      FrameInfo.fromJson({
        'frame': 0,
        'players': {
          'near': {
            'bbox': [80, 200, 50, 300],
          },
        },
      }),
    );
    final besideHitter = hitAnchor(measuredPlayer, measuredPlayer.hits.single)!;
    expect(besideHitter.dx, closeTo(105 / 518, 1e-6));
    expect(besideHitter.dy, closeTo(200 / 1340, 1e-6));

    final at = hitAnchor(seen, seen.hits.single)!;
    expect(at.dx, closeTo(0.25, 1e-6));
    expect(at.dy, closeTo(0.5, 1e-6));
    expect(hitBurstsAt(seen, 0).single.at, at);
    expect(hitBurstsAt(seen, 40), isEmpty); // more than 0.8 s after the hit

    // The shuttle cut off at the limit around the court: the feet, raised.
    final cut = record(
      const FrameInfo(frame: 0, nearPos: (x: 2.59, y: 3.35), shuttlePos: (x: 2.0, y: 14.4)),
    );
    final feet = hitAnchor(cut, cut.hits.single)!;
    expect(feet.dx, closeTo(0.5, 1e-6));
    expect(feet.dy, closeTo(0.75 - 0.22, 1e-6));
  });

  testWidgets('the burst stays inside the picture at any corner', (tester) async {
    for (final at in const [Offset(0, 0), Offset(1, 1), Offset(0.5, 0.5)]) {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ColoredBox(
              color: const Color(0xFF2E7D32),
              child: CustomPaint(
                size: const Size(640, 360),
                painter: HitBurstPainter(
                  word: 'SMASH!',
                  at: at,
                  accent: AppTheme.playerColorsLight.near,
                  progress: 0.5,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      // Set HIT_BURST_SHOT to a .png path to save the picture and look at it.
      final out = Platform.environment['HIT_BURST_SHOT'];
      if (out != null) {
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            out.replaceFirst('.png', '_${at.dx}_${at.dy}.png'),
          ).writeAsBytesSync(bytes!.buffer.asUint8List());
        });
      }
    }
  });
}
