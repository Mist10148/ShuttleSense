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
    final onCall = onColor(color);
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
      child: Card(
        color: color,
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 4,
            children: [
              ExcludeSemantics(
                child: Text(
                  word,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: onCall,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ExcludeSemantics(
                child: Text(detail, style: TextStyle(color: onCall)),
              ),
              if (onDecide != null)
                for (final c in ['in', 'out'])
                  if (review || c != call.effectiveCall)
                    FilledButton.tonal(
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
      ),
    );
  }
}
