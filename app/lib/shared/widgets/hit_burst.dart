import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// How long one burst stays on screen.
const Duration kHitBurstDuration = Duration(milliseconds: 750);

/// A hit whose moment passed longer ago than this (seconds) is not announced late.
const double kHitBurstWindowS = 0.8;

/// The word a hit pops up with: the stroke when the model named it, else a plain hit.
String hitBurstWord(String? stroke) => switch (stroke) {
  'smash' => 'SMASH!',
  'clear' => 'POW!',
  'drop' => 'DROP!',
  'net_shot' => 'TAP!',
  'lift' => 'WHOOSH!',
  'serve' => 'SERVE!',
  _ => 'HIT!',
};

/// One hit to announce over a video.
@immutable
class HitBurstEvent {
  const HitBurstEvent({required this.id, required this.who, this.stroke, this.at, this.timeS});

  /// From a Watch or live `hit` event as the server sends it; null when it has no id.
  ///
  /// [frame] is the newest analysed frame event (`players.<side>.bbox` in frame pixels of
  /// a [frameWidth] x [frameHeight] frame): the burst sits at the top of the hitter's box,
  /// where the racket is. Without it the burst goes to the hitter's half of the picture.
  static HitBurstEvent? fromJson(
    Map<dynamic, dynamic> hit, {
    Map<String, dynamic>? frame,
    num? frameWidth,
    num? frameHeight,
  }) {
    final id = hit['id'] ?? hit['frame'];
    if (id == null) return null;
    final side = (hit['player'] ?? 'near').toString();
    final who = (hit['hitter'] ?? side).toString();
    Offset? at;
    final players = frame?['display_players'] ?? frame?['players'];
    if (players is Map && frameWidth != null && frameHeight != null) {
      final slot = switch (who) {
        'near_1' => 'near',
        'far_1' => 'far',
        _ => who,
      };
      final player = players[slot] ?? players[side];
      final box = player is Map ? player['bbox'] : null;
      if (box is List && box.length == 4 && frameWidth > 0 && frameHeight > 0) {
        final b = [for (final v in box) (v as num).toDouble()];
        at = Offset((b[0] + b[2] / 2) / frameWidth, b[1] / frameHeight);
      }
    }
    return HitBurstEvent(
      id: id,
      who: who,
      stroke: hit['stroke'] as String?,
      at: at,
      timeS: (hit['time_s'] as num?)?.toDouble(),
    );
  }

  /// Tells one hit from the next; a burst plays once per id.
  final Object id;

  /// near, far, or a doubles slot (near_1 ... far_2): picks the colour and the default spot.
  final String who;
  final String? stroke;

  /// Where the hit happened, as fractions of the picture's width and height. Null: the
  /// hitter's half of the picture (near players are at the bottom, far ones at the top).
  final Offset? at;

  /// When the hit happened, in seconds of the video. With a clock ([HitBurstLayer.nowS])
  /// the burst waits for the video to reach it.
  final double? timeS;

  @override
  bool operator ==(Object other) =>
      other is HitBurstEvent &&
      other.id == id &&
      other.who == who &&
      other.stroke == stroke &&
      other.at == at &&
      other.timeS == timeS;

  @override
  int get hashCode => Object.hash(id, who, stroke, at, timeS);
}

/// A comic-book burst ("HIT!", "SMASH!", "POW!") that pops over a video when a player
/// hits the shuttle. Lay it over the picture in a [Stack]; it never takes pointer events
/// and is left out of the semantics tree (the hit is already announced in text).
///
/// Each of [events] plays once. With [nowS], the video's position in seconds, an event
/// with a time waits until the video reaches it, and one that is already long past is
/// skipped. Without it an event plays as soon as it is given. An event that leaves
/// [events] and comes back (the user seeks back onto a hit) plays again.
class HitBurstLayer extends StatefulWidget {
  const HitBurstLayer({super.key, required this.events, this.nowS});

  /// Watch & Analyze: every hit received so far, as the server sent them, keyed by id.
  HitBurstLayer.watch({
    super.key,
    required Map<Object?, Map<dynamic, dynamic>> hits,
    Map<String, dynamic>? frame,
    num? frameWidth,
    num? frameHeight,
    this.nowS,
  }) : events = [
         for (final hit in hits.values)
           ?HitBurstEvent.fromJson(
             hit,
             frame: frame,
             frameWidth: frameWidth,
             frameHeight: frameHeight,
           ),
       ];

  final List<HitBurstEvent> events;
  final double? nowS;

  @override
  State<HitBurstLayer> createState() => _HitBurstLayerState();
}

class _HitBurstLayerState extends State<HitBurstLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kHitBurstDuration,
  );

  /// Hits already shown, with their time: a new session reuses ids from 0, and the same
  /// id at another time is another hit.
  final Map<Object, double?> _played = {};
  HitBurstEvent? _current;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(HitBurstLayer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final ids = {for (final e in widget.events) e.id};
    _played.removeWhere((id, _) => !ids.contains(id));
    HitBurstEvent? next;
    for (final e in widget.events) {
      if (_played.containsKey(e.id) && _played[e.id] == e.timeS) continue;
      final now = widget.nowS, t = e.timeS;
      if (now != null && t != null && now < t) continue; // the video has not reached it yet
      _played[e.id] = t;
      // Too late to be the moment of the hit: not shown.
      if (now != null && t != null && now - t > kHitBurstWindowS) continue;
      next = e; // several at once: the newest one is shown
    }
    if (next != null) {
      _current = next;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final event = _current;
            if (event == null || !_controller.isAnimating) return const SizedBox.expand();
            return CustomPaint(
              size: Size.infinite,
              painter: HitBurstPainter(
                word: hitBurstWord(event.stroke),
                at: event.at ?? Offset(0.5, event.who.startsWith('near') ? 0.62 : 0.3),
                accent: colors.forPlayer(event.who),
                progress: _controller.value,
                still: still,
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Draws one burst at [progress] (0 to 1) of its life: a spiky star that pops out with an
/// overshoot, the word across it at a slant, then a quick fade.
class HitBurstPainter extends CustomPainter {
  HitBurstPainter({
    required this.word,
    required this.at,
    required this.accent,
    required this.progress,
    this.still = false,
  });

  final String word;
  final Offset at;
  final Color accent;
  final double progress;

  /// Reduced motion: no pop or wobble, only the fade.
  final bool still;

  static const _ink = Color(0xFF14110F);
  static const _paper = Color(0xFFFFE23A);
  static const _spikes = 13;

  /// The star's outline around the origin; every other point sits on the inner radius, and
  /// the spikes differ a little in length so it looks hand-drawn.
  static Path star(double radius, {double inner = 0.66, double turn = 0}) {
    final path = Path();
    for (var i = 0; i < _spikes * 2; i++) {
      final long = 1 + 0.14 * math.sin(i * 2.4);
      final r = radius * (i.isEven ? long : inner);
      final a = turn + i * math.pi / _spikes;
      final p = Offset(r * math.cos(a), r * math.sin(a));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final radius = (size.shortestSide * 0.17).clamp(34.0, 96.0);
    // The whole burst stays inside the picture, however close to an edge the hit was.
    final reach = radius * 1.36;
    final centre = Offset(
      (at.dx * size.width).clamp(
        math.min(reach, size.width / 2),
        math.max(size.width - reach, size.width / 2),
      ),
      (at.dy * size.height).clamp(
        math.min(reach, size.height / 2),
        math.max(size.height - reach, size.height / 2),
      ),
    );
    // Pop out past full size and settle (first third), hold, fade (last third).
    final pop = still ? 1.0 : Curves.elasticOut.transform((progress / 0.45).clamp(0.0, 1.0));
    final scale = still ? 1.0 : 0.35 + 0.65 * pop;
    final opacity = progress < 0.68 ? 1.0 : (1 - (progress - 0.68) / 0.32).clamp(0.0, 1.0);
    final wobble = still ? 0.0 : 0.06 * math.sin(progress * math.pi * 3) * (1 - progress);
    final alpha = (opacity * 255).round();

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(scale);
    canvas.rotate(-0.14 + wobble);

    // A hard offset shadow, the player's colour behind, the yellow burst on top.
    canvas.drawPath(
      star(radius).shift(Offset(radius * 0.07, radius * 0.09)),
      Paint()..color = _ink.withAlpha((alpha * 0.55).round()),
    );
    canvas.drawPath(star(radius * 1.16, turn: 0.12), Paint()..color = accent.withAlpha(alpha));
    final burst = star(radius);
    canvas.drawPath(burst, Paint()..color = _paper.withAlpha(alpha));
    canvas.drawPath(
      burst,
      Paint()
        ..color = _ink.withAlpha(alpha)
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = radius * 0.07,
    );

    // The word: thick ink outline, white fill, sized to span the burst.
    TextPainter text(Paint paint, double fontSize) => TextPainter(
      text: TextSpan(
        text: word,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          fontStyle: FontStyle.italic,
          letterSpacing: fontSize * 0.02,
          height: 1,
          foreground: paint,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var fontSize = radius * 0.62;
    final width = text(Paint(), fontSize).width;
    final span = radius * 1.75;
    if (width > span) fontSize *= span / width;
    final outline = text(
      Paint()
        ..color = _ink.withAlpha(alpha)
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = fontSize * 0.22,
      fontSize,
    );
    final fill = text(Paint()..color = Colors.white.withAlpha(alpha), fontSize);
    final origin = Offset(-fill.width / 2, -fill.height / 2);
    outline.paint(canvas, origin);
    fill.paint(canvas, origin);
    canvas.restore();
  }

  @override
  bool shouldRepaint(HitBurstPainter old) =>
      old.progress != progress ||
      old.word != word ||
      old.at != at ||
      old.accent != accent ||
      old.still != still;
}
