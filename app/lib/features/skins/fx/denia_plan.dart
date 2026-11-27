import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Timeline of a Denia switch (Wonderboard deniaPlan.ts), in ms from the start. Entering a
/// Denia theme: bubbles rise, the theme changes under them, then they pop. Between Light and
/// Dark the same, shorter. Leaving: a short goodbye.
@immutable
class DeniaPlan {
  const DeniaPlan({
    required this.bubbles,
    required this.applyAt,
    required this.popFrom,
    required this.popTo,
    required this.endAt,
  });

  final int bubbles;
  final int applyAt;
  final int popFrom;
  final int popTo;
  final int endAt;

  static const enter = DeniaPlan(bubbles: 34, applyAt: 620, popFrom: 820, popTo: 1500, endAt: 1800);
  static const formChange = DeniaPlan(
    bubbles: 16,
    applyAt: 260,
    popFrom: 380,
    popTo: 820,
    endAt: 1100,
  );
  static const leave = DeniaPlan(bubbles: 14, applyAt: 160, popFrom: 300, popTo: 680, endAt: 860);
}

/// Which Denia switch is playing.
enum DeniaSwitchKind {
  enterLight,
  enterDark,
  formLight,
  formDark,
  leave;

  DeniaPlan get plan => switch (this) {
    leave => DeniaPlan.leave,
    formLight || formDark => DeniaPlan.formChange,
    enterLight || enterDark => DeniaPlan.enter,
  };

  bool get dark => this == enterDark || this == formDark;
  bool get isForm => this == formLight || this == formDark;

  /// Light rises, Dark (and leaving) falls.
  bool get rising => this == enterLight || this == formLight;

  /// The short switches: the form change and leaving.
  bool get isShort => this != enterLight && this != enterDark;
}

/// One bubble of a run.
@immutable
class DeniaBubble {
  const DeniaBubble({
    required this.x,
    required this.size,
    required this.delay,
    required this.rise,
    required this.sway,
    required this.popAt,
    required this.hue,
  });

  /// Centre, % of the window width.
  final double x;

  /// Diameter in px.
  final double size;

  /// Ms before it starts to rise.
  final int delay;

  /// How far it rises, % of the window height (it starts just under the bottom edge).
  final double rise;

  /// Sideways drift in px.
  final double sway;

  /// Ms from the start when it pops.
  final int popAt;

  /// 0 pink, 1 pale blue, 2 violet.
  final int hue;
}

/// A small repeatable random source (xorshift32, as in Wonderboard), so a seed always gives
/// the same bubbles.
class XorShift32 {
  XorShift32(int seed) : _s = (seed & 0xffffffff) == 0 ? 1 : seed & 0xffffffff;

  int _s;

  double next() {
    _s ^= (_s << 13) & 0xffffffff;
    _s ^= _s >> 17;
    _s ^= (_s << 5) & 0xffffffff;
    return _s / 4294967296;
  }
}

/// The bubbles of one run: spread over the width with some jitter, each popping in the plan's
/// pop window.
List<DeniaBubble> deniaBubbles(DeniaPlan p, [int seed = 1]) {
  final r = XorShift32(seed);
  final slot = 100 / p.bubbles;
  return [
    for (var i = 0; i < p.bubbles; i++)
      DeniaBubble(
        x: math.min(98, math.max(2, (i + 0.5) * slot + (r.next() - 0.5) * slot * 1.6)),
        size: 26 + (r.next() * r.next() * 110).roundToDouble(),
        delay: (r.next() * p.applyAt * 0.7).round(),
        rise: 35 + r.next() * 70,
        sway: ((r.next() - 0.5) * 80).roundToDouble(),
        popAt: (p.popFrom + r.next() * (p.popTo - p.popFrom)).round(),
        hue: (r.next() * 3).floor(),
      ),
  ];
}

/// When pop sounds play: a handful spread over the pop window, never more than [max].
List<int> popTimes(List<DeniaBubble> b, [int max = 7]) {
  final t = b.map((x) => x.popAt).toList()..sort();
  if (t.length <= max) return t;
  return [for (var i = 0; i < max; i++) t[((i * (t.length - 1)) / (max - 1)).round()]];
}

/// One music-box note.
@immutable
class ChimeNote {
  const ChimeNote(this.at, this.freq, this.vol);
  final int at;
  final double freq;
  final double vol;
}

/// One bubble bloop, panned (-1 left to 1 right) to where its bubble popped.
@immutable
class PopNote {
  const PopNote(this.at, this.freq, this.pan);
  final int at;
  final double freq;
  final double pan;
}

/// Band-passed noise sweeping while the bubbles rise.
@immutable
class Whoosh {
  const Whoosh({
    required this.at,
    required this.dur,
    required this.from,
    required this.to,
    required this.vol,
  });
  final int at;
  final int dur;
  final double from;
  final double to;
  final double vol;
}

/// The sound of one switch.
@immutable
class DeniaScore {
  const DeniaScore(this.whoosh, this.chimes, this.pops);
  final Whoosh whoosh;
  final List<ChimeNote> chimes;
  final List<PopNote> pops;

  /// The last moment anything sounds, in ms (with the ring of the longest note).
  int get lengthMs {
    var end = whoosh.at + whoosh.dur + 300;
    for (final c in chimes) {
      end = math.max(end, c.at + 1600);
    }
    for (final p in pops) {
      end = math.max(end, p.at + 150);
    }
    return end;
  }
}

/// Light rises in E major and ends on a high sparkle; Dark falls through G minor.
const _rise = [659.25, 830.61, 987.77, 1318.51, 1661.22];
const _fall = [1174.66, 932.33, 783.99, 587.33, 392.0];

/// The score of one switch, from its plan and bubbles (Wonderboard soundPlan).
DeniaScore deniaScore(DeniaSwitchKind kind, List<DeniaBubble> b) {
  final p = kind.plan, short = kind.isShort, up = kind.rising;
  final notes = kind == DeniaSwitchKind.leave
      ? const [880.0, 659.25]
      : (up ? _rise : _fall).sublist(0, short ? 3 : 5);
  final step = short ? 80 : 95;
  final start = math.max(0, p.applyAt - step * (notes.length - 1) * 0.6);
  final chimes = [
    for (var i = 0; i < notes.length; i++)
      ChimeNote(
        (start + i * step).round(),
        notes[i],
        double.parse((0.16 - i * 0.012).toStringAsFixed(3)),
      ),
  ];
  final times = popTimes(b, short ? 5 : 9);
  final byTime = [...b]..sort((x, y) => x.popAt.compareTo(y.popAt));
  final pops = <PopNote>[];
  for (var i = 0; i < times.length; i++) {
    final at = times[i];
    final bub = byTime.isEmpty
        ? null
        : byTime.firstWhere((x) => x.popAt == at, orElse: () => byTime.first);
    final size = bub?.size ?? 60; // bigger bubbles pop lower
    final freq =
        math.min(900.0, math.max(320.0, 1150 - size * 5.5)).roundToDouble() + ((i * 37) % 5) * 12;
    final pan = bub == null ? 0.0 : ((bub.x - 50) / 50).clamp(-0.85, 0.85);
    pops.add(PopNote(at, freq, double.parse(pan.toStringAsFixed(2))));
  }
  return DeniaScore(
    Whoosh(
      at: 0,
      dur: math.max(300, p.applyAt + 160),
      from: up ? 350 : 2600,
      to: up ? 3200 : 500,
      vol: short ? 0.07 : 0.1,
    ),
    chimes,
    pops,
  );
}
