import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../data/models/clip_record.dart';

/// How long after a landing its banner stays up.
const kLineCallBannerSeconds = 3.0;

/// The line call to show at [frameIndex]: the latest one in the last few seconds, otherwise
/// the earliest one still waiting for the user's review (a newer call must not hide it).
LineCall? bannerCall(ClipRecord record, int frameIndex, {bool prioritizeReview = false}) {
  final fps = record.fps == 0 ? 30.0 : record.fps;
  final latest = record.lineCallAt(frameIndex);
  if (latest == null) return null;
  final recent = (frameIndex - latest.frame) / fps <= kLineCallBannerSeconds;
  if (recent && !prioritizeReview) return latest;
  LineCall? waiting;
  for (final c in record.lineCalls) {
    if (c.frame <= frameIndex && c.needsReview && (waiting == null || c.frame < waiting.frame)) {
      waiting = c;
    }
  }
  return waiting ?? (recent ? latest : null);
}

/// F20: big IN / OUT banner for an automated call, with its margin and confidence.
/// An UNCERTAIN call asks the user to confirm or override it; a reviewed one can be changed.
class LineCallBanner extends StatelessWidget {
  const LineCallBanner({super.key, required this.call, this.onDecide, this.busy = false});

  final LineCall call;

  /// Called with "in" or "out"; null hides the buttons (read-only).
  final ValueChanged<String>? onDecide;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final review = call.needsReview;
    final color = StatusColors.of(context).forCall(isIn: call.isIn, review: review);
    final p = AppPalette.of(context);
    final word = review ? 'UNCERTAIN' : (call.isIn ? 'IN' : 'OUT');
    final margin = call.marginCm.abs().round();
    final side = call.marginCm >= 0 ? 'inside' : 'outside';
    final detail = [
      'Automated call · ${(call.confidence * 100).round()}% confidence',
      '$margin cm $side the line',
      if (call.reviewed) 'Confirmed by referee',
      if (review) 'looks ${call.call.toUpperCase()}, please confirm',
    ].join(' · ');
    return Semantics(
      liveRegion: true,
      label: 'Line call $word. $detail',
      // A quiet card in the page's surface: the call's colour is on the word and the edge
      // only, so a green or red slab does not outshout the video above it.
      child: Container(
        margin: const EdgeInsets.only(top: Spacing.sm),
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.sm),
        decoration: BoxDecoration(
          color: Color.alphaBlend(color.withValues(alpha: 0.10), p.surface),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            ExcludeSemantics(
              child: Text(
                word,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: Color.lerp(color, p.ink, 0.15),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            ExcludeSemantics(
              child: Text(detail, style: theme.textTheme.bodyMedium?.copyWith(color: p.text2)),
            ),
            if (onDecide != null)
              for (final c in ['in', 'out'])
                if (review || c != call.effectiveCall)
                  OutlinedButton(
                    onPressed: busy ? null : () => onDecide!(c),
                    child: Text(
                      review && c == call.call
                          ? 'Confirm ${c.toUpperCase()}'
                          : 'Call ${c.toUpperCase()}',
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}
