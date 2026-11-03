import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/disclaimers.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/start_score_field.dart';
import '../calibration/calibration_screen.dart';
import '../mode/mode_screen.dart';
import '../results/widgets/court_minimap.dart';
import '../results/widgets/line_call_banner.dart';
import '../results/widgets/results_layout.dart';
import '../results/widgets/scoreboard.dart';
import '../results/widgets/status_strip.dart';
import '../results/widgets/stroke_timeline.dart';
import 'live_controller.dart';

/// F19 / C5: camera preview, optional court calibration on a still, then the live results
/// layout fed by WS /live events. Stopping saves the session to History.
class LiveScreen extends ConsumerWidget {
  const LiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(liveControllerProvider);
    final controller = ref.read(liveControllerProvider.notifier);
    ref.listen(liveControllerProvider.select((s) => s.notice), (_, notice) {
      if (notice == null) return;
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(notice.text)));
    });
    final waiting = {LivePhase.connecting, LivePhase.reconnecting}.contains(state.phase);
    final streaming = {
      LivePhase.connecting,
      LivePhase.live,
      LivePhase.reconnecting,
      LivePhase.stopping,
    }.contains(state.phase);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live'),
        actions: [
          if (waiting)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: OutlinedButton.icon(
                onPressed: controller.cancel,
                icon: const Icon(Icons.close),
                label: const Text('Cancel'),
              ),
            )
          else if (streaming)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                onPressed: state.phase == LivePhase.live ? controller.stop : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
            )
          else
            const SwitchModeButton(),
        ],
      ),
      body: SafeArea(
        child: switch (state.phase) {
          LivePhase.starting => const MessageView(
            icon: Icons.videocam_outlined,
            message: 'Starting the camera…',
          ),
          LivePhase.error => _ErrorView(state: state, onRetry: controller.openCamera),
          LivePhase.ready => _ReadyView(state: state),
          LivePhase.calibrating => _CalibrateView(state: state),
          LivePhase.saved => _SavedView(
            jobId: state.savedJobId,
            onNewSession: controller.openCamera,
          ),
          _ => _LiveView(state: state),
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.state, required this.onRetry});

  final LiveState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              state.permissionDenied ? Icons.no_photography_outlined : Icons.error_outline,
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(state.error ?? 'Something went wrong', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadyView extends ConsumerWidget {
  const _ReadyView({required this.state});

  final LiveState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(liveControllerProvider.notifier);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MaxWidthPreview(child: controller.source?.preview()),
        const SizedBox(height: 12),
        Text(
          'Put the ${state.cameraLabel.toLowerCase()} on a tripod, high and behind a baseline, '
          'with the whole court in view. Calibrate the court for the minimap, speed and line '
          'calls.',
        ),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(state.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: controller.calibrate,
              icon: const Icon(Icons.crop_free),
              label: const Text('Calibrate court'),
            ),
            OutlinedButton.icon(
              onPressed: () {
                // Without a court there are no line calls, but awards and corrections still
                // keep score from the start score.
                final score = ref.read(liveStartScoreProvider.notifier);
                controller.start(startScore: score.state);
                score.state = null; // belongs to this session only
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start without court'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        StartScoreField(
          value: ref.watch(liveStartScoreProvider),
          onChanged: (s) => ref.read(liveStartScoreProvider.notifier).state = s,
        ),
        const SizedBox(height: 16),
        Text(kLineCallNote, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// Keeps the preview a sensible size on wide screens.
class MaxWidthPreview extends StatelessWidget {
  const MaxWidthPreview({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: child ?? const ColoredBox(color: Colors.black),
        ),
      ),
    ),
  );
}

class _CalibrateView extends ConsumerStatefulWidget {
  const _CalibrateView({required this.state});

  final LiveState state;

  @override
  ConsumerState<_CalibrateView> createState() => _CalibrateViewState();
}

class _CalibrateViewState extends ConsumerState<_CalibrateView> {
  final List<Corner> _corners = [];

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(liveControllerProvider.notifier);
    final size = widget.state.stillSize!;
    final next = _corners.length < 4 ? _corners.length : null;
    final convex = isConvex(_corners);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CornerDiagram(next: next),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  next == null
                      ? (convex
                            ? 'All 4 corners set. Drag to adjust, then go live.'
                            : 'The corners cross over. Drag them into order.')
                      : 'Tap the ${kCornerNames[next]} corner of the singles court '
                            '(${next + 1} of 4).',
                ),
              ),
              IconButton(
                tooltip: 'Undo',
                onPressed: _corners.isEmpty ? null : () => setState(_corners.removeLast),
                icon: const Icon(Icons.undo),
              ),
            ],
          ),
        ),
        Expanded(
          child: CornerCanvas(
            image: MemoryImage(widget.state.still!),
            width: size.width,
            height: size.height,
            corners: _corners,
            onTap: (c) {
              if (_corners.length < 4) setState(() => _corners.add(c));
            },
            onMove: (i, c) => setState(() => _corners[i] = c),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton(onPressed: controller.cancelCalibration, child: const Text('Back')),
              FilledButton.icon(
                onPressed: convex
                    ? () {
                        final score = ref.read(liveStartScoreProvider.notifier);
                        controller.start(corners: List.of(_corners), startScore: score.state);
                        score.state = null; // belongs to this session only
                      }
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Go live'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SavedView extends StatelessWidget {
  const _SavedView({required this.jobId, required this.onNewSession});

  final String? jobId;
  final VoidCallback onNewSession;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 48),
            const SizedBox(height: 12),
            Text(
              jobId == null
                  ? 'No frames reached the server, so nothing was saved.'
                  : 'Session saved to History. The annotated video is rendering.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (jobId != null)
                  FilledButton.icon(
                    onPressed: () => context.go(Routes.job(jobId!)),
                    icon: const Icon(Icons.insights),
                    label: const Text('Open results'),
                  ),
                OutlinedButton.icon(
                  onPressed: onNewSession,
                  icon: const Icon(Icons.videocam_outlined),
                  label: const Text('New session'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveView extends ConsumerWidget {
  const _LiveView({required this.state});

  final LiveState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(liveControllerProvider.notifier);
    final record = state.record;
    final frameIndex = state.frameIndex;
    final call = bannerCall(record, frameIndex);
    final size = state.size;
    final video = AspectRatio(
      aspectRatio: size == null || size.height == 0 ? 16 / 9 : size.width / size.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            controller.source?.preview() ?? const ColoredBox(color: Colors.black),
            if (size != null)
              CustomPaint(
                painter: LiveOverlayPainter(
                  size: size,
                  trail: state.trail,
                  players: state.players,
                  colors: PlayerColors.of(context),
                ),
              ),
            if (state.phase != LivePhase.live)
              ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Text(switch (state.phase) {
                    LivePhase.connecting => 'Connecting… the server may be loading its models',
                    LivePhase.reconnecting => 'Connection lost, reconnecting…',
                    LivePhase.stopping => 'Saving the session…',
                    _ => '',
                  }, style: const TextStyle(color: Colors.white, fontSize: 18)),
                ),
              ),
          ],
        ),
      ),
    );
    return ResultsLayout(
      video: video,
      status: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LiveStatusBar(state: state),
          StatusStrip(
            rallyState: state.rallyState,
            speedKmh: state.speedKmh,
            peakSpeedKmh: state.peakSpeedKmh,
            strokeCount: state.strokesInRally,
          ),
          if (call != null)
            LineCallBanner(call: call, onDecide: (c) => controller.overrideCall(call.id, c)),
        ],
      ),
      timeline: StrokeTimeline(
        hits: state.hits,
        currentHitId: state.hits.isEmpty ? null : state.hits.last.id,
        onSeek: (_) {},
      ),
      minimap: CourtMinimap(record: record, frameIndex: frameIndex),
      scoreboard: Scoreboard(record: record, frameIndex: frameIndex, onCorrect: controller.correct),
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
  final List<({double x, double y})> trail;
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
          ..color = colors.forSide(side)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    for (var i = 0; i < trail.length; i++) {
      final age = (trail.length - 1 - i) / trail.length;
      canvas.drawCircle(
        Offset(trail[i].x * sx, trail[i].y * sy),
        5 - 3 * age,
        Paint()..color = colors.shuttle.withValues(alpha: 1 - 0.8 * age),
      );
    }
  }

  @override
  bool shouldRepaint(LiveOverlayPainter old) =>
      old.trail != trail || old.players != players || old.size != size;
}
