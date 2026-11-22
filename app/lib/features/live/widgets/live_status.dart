import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/shuttle_speed.dart';
import '../live_controller.dart';

/// The newest hit: stroke, player and speed, the live "callout".
class HitCallout extends StatelessWidget {
  const HitCallout({super.key, required this.hit});

  final Hit hit;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final stroke = kStrokeLabels[hit.stroke] ?? 'Hit';
    final speed = hit.speedKmh == null ? '' : ' · ${hit.speedKmh!.round()} km/h (est.)';
    final side = playerLabel(hit.who);
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.sm),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(Icons.bolt, color: colors.forPlayer(hit.who), size: 20),
            const SizedBox(width: Spacing.xs),
            Flexible(
              child: Text(
                '$stroke by $side$speed',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rally timer, latency, frames sent and analysed, and the reduced-quality warning.
class LiveStatusBar extends StatelessWidget {
  const LiveStatusBar({super.key, required this.state});

  final LiveState state;

  @override
  Widget build(BuildContext context) {
    final start = state.rallyStartFrame;
    final fps = state.fps == 0 ? 30.0 : state.fps;
    final seconds = start == null ? null : ((state.frameIndex - start) / fps).clamp(0, 9999);
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Chip(
          avatar: const Icon(Icons.timer_outlined, size: 16),
          label: Text(seconds == null ? 'Rally –' : 'Rally ${seconds.toStringAsFixed(0)} s'),
          visualDensity: VisualDensity.compact,
        ),
        Chip(
          avatar: const Icon(Icons.network_check, size: 16),
          label: Text(
            state.latencyMs == null ? 'Latency –' : 'Latency ${state.latencyMs!.round()} ms',
          ),
          visualDensity: VisualDensity.compact,
        ),
        Chip(
          avatar: const Icon(Icons.photo_camera_outlined, size: 16),
          label: Text(
            state.processedFrames == null
                ? 'Sent ${state.sentFrames}'
                : 'Sent ${state.sentFrames} · analysed ${state.processedFrames}',
          ),
          visualDensity: VisualDensity.compact,
        ),
        if (state.reducedQuality)
          Tooltip(
            message: state.qualityReason ?? 'The server lowered the resolution to keep up',
            child: Chip(
              backgroundColor: scheme.errorContainer,
              avatar: Icon(Icons.warning_amber, size: 16, color: scheme.onErrorContainer),
              label: Text('Reduced quality', style: TextStyle(color: scheme.onErrorContainer)),
              visualDensity: VisualDensity.compact,
            ),
          ),
        if (state.stages['tracking'] == false || state.stages['pose'] == false)
          Chip(
            avatar: const Icon(Icons.info_outline, size: 16),
            label: Text(
              state.stages['synthetic'] == true
                  ? 'Demo server: synthetic rallies, not your camera'
                  : state.stages['tracking'] == false
                  ? 'No shuttle tracking on this server'
                  : 'No pose model on this server',
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}

/// Player boxes and the shuttle trail over the camera preview, in processing pixels.
class LiveOverlayPainter extends CustomPainter {
  LiveOverlayPainter({
    required this.size,
    required this.trail,
    required this.players,
    required this.colors,
  });

  final ({int width, int height}) size;
  final List<LiveTrailPoint> trail;
  final Map<String, LivePlayer> players;
  final PlayerColors colors;

  @override
  void paint(Canvas canvas, Size box) {
    final sx = box.width / size.width, sy = box.height / size.height;
    for (final MapEntry(key: side, value: p) in players.entries) {
      final b = p.bbox;
      canvas.drawRect(
        Rect.fromLTWH(b[0] * sx, b[1] * sy, b[2] * sx, b[3] * sy),
        Paint()
          ..color = colors.forPlayer(side).withValues(alpha: p.held ? 0.4 : 1)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    paintShuttleTrail(
      canvas,
      [
        for (final sample in trail)
          (
            point: Offset(sample.x * sx, sample.y * sy),
            speed: sample.speed,
            approximate: false,
            connected: true,
          ),
      ],
      hasCurrent: trail.isNotEmpty,
      neutral: colors.shuttle,
    );
  }

  @override
  bool shouldRepaint(LiveOverlayPainter old) =>
      old.trail != trail || old.players != players || old.size != size || old.colors != colors;
}
