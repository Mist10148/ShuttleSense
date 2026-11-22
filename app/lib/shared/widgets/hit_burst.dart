import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// How long one burst stays on screen.
const Duration kHitBurstDuration = Duration(milliseconds: 420);

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
    final shuttle = frame?['shuttle'];
    final sameFrame = hit['frame'] != null && hit['frame'] == frame?['frame'];
    if (sameFrame && shuttle is Map && shuttle['visible'] == 1) {
      at = hitBurstPicturePoint(shuttle['x'], shuttle['y'], frameWidth, frameHeight);
    }
    if (at == null && players is Map && frameWidth != null && frameHeight != null) {
      final slot = switch (who) {
        'near_1' => 'near',
        'far_1' => 'far',
        _ => who,
      };
      final player = players[slot] ?? players[side];
      final box = player is Map ? player['bbox'] : null;
      if (box is List && box.length == 4 && box.every((v) => v is num)) {
        at = hitBurstPicturePoint(
          (box[0] as num) + (box[2] as num) / 2,
          box[1],
          frameWidth,
          frameHeight,
        );
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

Offset? hitBurstPicturePoint(Object? x, Object? y, num? width, num? height) {
  if (x is! num || y is! num || width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  if (!x.isFinite ||
      !y.isFinite ||
      !width.isFinite ||
      !height.isFinite ||
      x < 0 ||
      x > width ||
      y < 0 ||
      y > height) {
    return null;
  }
  return Offset(x / width, y / height);
}

/// Supplies the complete live hit sequence through the existing video overlay.
class HitBurstFeed extends StatefulWidget {
  const HitBurstFeed({
    super.key,
    required this.session,
    required this.count,
    required this.eventAt,
    required this.child,
  });

  final Object? session;
  final int count;
  final HitBurstEvent Function(int) eventAt;
  final Widget child;

  @override
  State<HitBurstFeed> createState() => _HitBurstFeedState();
}

class _HitBurstFeedState extends State<HitBurstFeed> {
  int _read = 0;

  @override
  void didUpdateWidget(HitBurstFeed oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session || widget.count < _read) _read = 0;
  }

  List<HitBurstEvent> take() {
    final events = [for (var i = _read; i < widget.count; i++) widget.eventAt(i)];
    _read = widget.count;
    return events;
  }

  @override
  Widget build(BuildContext context) => _HitBurstFeedData(
    session: widget.session,
    count: widget.count,
    take: take,
    child: widget.child,
  );
}

class _HitBurstFeedData extends InheritedWidget {
  const _HitBurstFeedData({
    required this.session,
    required this.count,
    required this.take,
    required super.child,
  });

  final Object? session;
  final int count;
  final List<HitBurstEvent> Function() take;

  @override
  bool updateShouldNotify(_HitBurstFeedData oldWidget) =>
      oldWidget.session != session || oldWidget.count != count;
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
  const HitBurstLayer({super.key, required this.events, this.nowS, this.session}) : _watch = false;

  /// Watch & Analyze: every hit received so far, as the server sent them, keyed by id.
  HitBurstLayer.watch({
    super.key,
    required Map<Object?, Map<dynamic, dynamic>> hits,
    Map<String, dynamic>? frame,
    num? frameWidth,
    num? frameHeight,
    this.nowS,
  }) : session = null,
       _watch = true,
       events = [
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
  final Object? session;
  final bool _watch;

  @override
  State<HitBurstLayer> createState() => _HitBurstLayerState();
}

class _HitBurstLayerState extends State<HitBurstLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kHitBurstDuration,
  )..addStatusListener(_onStatus);

  final Set<(Object, double?)> _seen = {};
  final Queue<HitBurstEvent> _pending = Queue();
  HitBurstEvent? _current;
  Object? _session;
  double? _lastClock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(HitBurstLayer old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final feed = context.dependOnInheritedWidgetOfExactType<_HitBurstFeedData>();
    final session = feed?.session ?? widget.session;
    final now = widget.nowS;
    final elapsed = now == null || _lastClock == null ? null : now - _lastClock!;
    final seeked = elapsed != null && (elapsed < -0.02 || elapsed > kHitBurstWindowS);
    final allowLateWatchHit = widget._watch && elapsed != null && !seeked;
    if (session != _session || seeked) {
      _seen.clear();
      _pending.clear();
      _current = null;
      _controller.stop();
    }
    _session = session;
    _lastClock = now;

    Iterable<HitBurstEvent> events = widget.events;
    if (feed != null) {
      events = feed.take();
    } else {
      final keys = {for (final event in events) (event.id, event.timeS)};
      _seen.retainAll(keys);
    }
    for (final event in events) {
      final t = event.timeS;
      if (now != null && t != null && now < t) continue;
      if (!_seen.add((event.id, t))) continue;
      if (now != null && t != null && now - t > kHitBurstWindowS && !allowLateWatchHit) continue;
      _pending.add(event);
    }
    if (!_controller.isAnimating) _showNext();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _showNext();
  }

  void _showNext() {
    _current = _pending.isEmpty ? null : _pending.removeFirst();
    if (_current != null) _controller.forward(from: 0);
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
                at:
                    event.at ??
                    (event.who.startsWith('near')
                        ? const Offset(0.15, 0.72)
                        : const Offset(0.85, 0.28)),
                offsetFromAnchor: event.at != null,
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
    this.offsetFromAnchor = true,
  });

  final String word;
  final Offset at;
  final Color accent;
  final double progress;
  final bool offsetFromAnchor;

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
    final radius = math.min(size.shortestSide / 4, (size.shortestSide * 0.085).clamp(16.0, 48.0));
    // Include the shadow, outer spikes and peak animation scale.
    final reach = radius * 1.58;
    final room = (Offset.zero & size).deflate(reach);
    final anchor = Offset(at.dx * size.width, at.dy * size.height);
    final shift = reach + 8;
    final candidates = at.dx < 0.5
        ? [Offset(shift, 0), Offset(0, -shift), Offset(0, shift), Offset(-shift, 0)]
        : [Offset(-shift, 0), Offset(0, -shift), Offset(0, shift), Offset(shift, 0)];
    final centre = candidates
        .map((offset) => anchor + (offsetFromAnchor ? offset : Offset.zero))
        .firstWhere(
          room.contains,
          orElse: () => Offset(
            (anchor.dx + (offsetFromAnchor ? candidates.first.dx : 0.0)).clamp(
              room.left,
              room.right,
            ),
            anchor.dy.clamp(room.top, room.bottom),
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
    var fontSize = math.max(10.0, radius * 0.62);
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
