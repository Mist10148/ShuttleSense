import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../data/models/court_view.dart';
import 'stroke_timeline.dart' show formatClock;

/// One labelled mark on the [ShotMarkerBar].
class ShotMark {
  const ShotMark({
    required this.frame,
    required this.timeS,
    required this.label,
    required this.color,
    required this.description,
    this.isCall = false,
    this.current = false,
  });

  final int frame;
  final double timeS;
  final String label;
  final Color color;

  /// What a screen reader and the tooltip say ("Serve, Near player, 0:01.0").
  final String description;

  /// A line call: drawn as an upright tick instead of a dot.
  final bool isCall;
  final bool current;

  Moment get moment => Moment(frame: frame, timeS: timeS);
}

/// The strokes and line calls of the clip as marks along its length.
List<ShotMark> shotMarks(
  ClipRecord record,
  int frameIndex, {
  required PlayerColors players,
  required StatusColors status,
  required Color accent,
  SideNames sides = SideNames.ends,
}) {
  final current = record.hitAt(frameIndex);
  return [
    for (final h in record.hits)
      ShotMark(
        frame: h.frame,
        timeS: h.timeS,
        label: kStrokeLabels[h.stroke] ?? 'Hit',
        color: h.id == current?.id ? accent : players.forPlayer(h.who),
        description:
            '${kStrokeLabels[h.stroke] ?? 'Unclassified'}, ${sides.player(h.who)} player, '
            '${formatClock(h.timeS)}',
        current: h.id == current?.id,
      ),
    for (final c in record.lineCalls)
      ShotMark(
        frame: c.frame,
        timeS: c.timeS,
        label: c.isIn ? 'In' : 'Out',
        color: status.forCall(isIn: c.isIn, review: c.needsReview),
        description: 'Line call ${c.isIn ? 'in' : 'out'}, ${formatClock(c.timeS)}',
        isCall: true,
      ),
  ];
}

/// The clip as a track under the video: how far playback is, and every stroke and line call
/// as a labelled mark. Tapping a mark plays that moment; tapping or dragging along the track
/// scrubs to that frame ([onScrub]).
class ShotMarkerBar extends StatelessWidget {
  const ShotMarkerBar({
    super.key,
    required this.record,
    required this.frameIndex,
    required this.onSeek,
    this.onScrub,
  });

  final ClipRecord record;
  final int frameIndex;
  final ValueChanged<Moment> onSeek;

  /// Called with a frame index while the track is tapped or dragged.
  final ValueChanged<int>? onScrub;

  static const double _labelHeight = 18;
  static const double height = 48;

  @override
  Widget build(BuildContext context) {
    final a = AnalysisColors.of(context);
    final p = AppPalette.of(context);
    final t = TactileTokens.of(context);
    final marks = shotMarks(
      record,
      frameIndex,
      players: PlayerColors.of(context),
      status: StatusColors.of(context),
      accent: a.accentInk,
      sides: CourtSides.of(context),
    );
    final last = record.numFrames <= 1 ? 1 : record.numFrames - 1;
    final progress = (frameIndex / last).clamp(0.0, 1.0);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          double x(int frame) => (frame / last).clamp(0.0, 1.0) * w;
          void scrub(double dx) => onScrub?.call(((dx / w).clamp(0.0, 1.0) * last).round());
          // Labels that would overlap the one before are left out; the current stroke's
          // label always shows.
          final shown = <ShotMark>{};
          double? lastRight;
          for (final m in [...marks]..sort((a, b) => a.frame.compareTo(b.frame))) {
            final center = x(m.frame);
            final half = m.label.length * 3.6 + 4;
            if (m.current || lastRight == null || center - half > lastRight) {
              shown.add(m);
              lastRight = center + half;
            }
          }
          const trackTop = _labelHeight + 13;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: trackTop - 1,
                height: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: a.track, borderRadius: BorderRadius.circular(3)),
                ),
              ),
              // The played part, in the accent blue.
              Positioned(
                left: 0,
                width: progress * w,
                top: trackTop - 1,
                height: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: t.primary,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              // Tap or drag anywhere along the track to scrub; the marks on top keep their taps.
              if (onScrub != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: trackTop - 16,
                  height: 36,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapUp: (d) => scrub(d.localPosition.dx),
                      onHorizontalDragStart: (d) => scrub(d.localPosition.dx),
                      onHorizontalDragUpdate: (d) => scrub(d.localPosition.dx),
                    ),
                  ),
                ),
              for (final m in shown)
                Positioned(
                  left: (x(m.frame) - 40).clamp(-8.0, w - 72),
                  width: 80,
                  top: 0,
                  height: _labelHeight,
                  child: ExcludeSemantics(
                    child: Text(
                      m.label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.visible,
                      style: TextStyle(
                        color: Color.lerp(m.color, p.ink, m.current ? 0 : 0.25),
                        fontSize: 13,
                        fontWeight: m.current ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              for (final m in marks)
                Positioned(
                  left: x(m.frame) - 14,
                  top: trackTop - 12,
                  width: 28,
                  height: 28,
                  child: Tooltip(
                    message: m.description,
                    child: Semantics(
                      button: true,
                      label: m.description,
                      child: InkResponse(
                        radius: 18,
                        onTap: () => onSeek(m.moment),
                        child: Center(
                          child: _Mark(mark: m, ring: p.surface),
                        ),
                      ),
                    ),
                  ),
                ),
              // The playhead.
              Positioned(
                left: progress * w - 7,
                top: trackTop - 5,
                width: 14,
                height: 14,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: t.raisedTop,
                      shape: BoxShape.circle,
                      border: Border.all(color: t.primary, width: 3),
                      boxShadow: [
                        BoxShadow(color: t.shade, blurRadius: 4, offset: const Offset(0, 1)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({required this.mark, required this.ring});

  final ShotMark mark;
  final Color ring;

  @override
  Widget build(BuildContext context) {
    if (mark.isCall) {
      return Container(width: 2, height: 20, color: mark.color);
    }
    final size = mark.current ? 18.0 : 12.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: mark.color,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: mark.current ? 3 : 2),
      ),
    );
  }
}
