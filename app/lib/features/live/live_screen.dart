import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/clip_record.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/disclaimers.dart';
import '../../shared/widgets/match_setup_field.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/start_score_field.dart';
import '../../shared/widgets/stroke_model_field.dart';
import '../calibration/calibration_screen.dart';
import '../mode/mode_screen.dart';
import '../results/widgets/court_minimap.dart';
import '../results/widgets/line_call_banner.dart';
import '../results/widgets/scoreboard.dart';
import '../results/widgets/status_strip.dart';
import '../results/widgets/stroke_timeline.dart';
import '../upload/upload_controller.dart';
import 'live_controller.dart';
import 'widgets/live_coach_panel.dart';
import 'widgets/live_status.dart';

export 'widgets/live_coach_panel.dart';
export 'widgets/live_status.dart';

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
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
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
            if (state.savedJobId case final String id)
              TextButton(
                onPressed: () => context.go(Routes.job(id)),
                child: const Text('Open results'),
              )
            else if (state.sessionId != null)
              TextButton(
                onPressed: () => context.go(Routes.history),
                child: const Text('Open History'),
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
        const SizedBox(height: 8),
        Text(kLineCallNote, style: Theme.of(context).textTheme.bodySmall),
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
                // Cleared by the controller once the session has started.
                controller.start(startScore: ref.read(liveStartScoreProvider));
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start without court'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        StartScoreField(
          value: ref.watch(liveStartScoreProvider),
          doubles: ref.watch(liveMatchSetupProvider).doubles,
          onChanged: (s) => ref.read(liveStartScoreProvider.notifier).state = s,
        ),
        MatchSetupField(
          value: ref.watch(liveMatchSetupProvider),
          onChanged: ref.read(liveMatchSetupProvider.notifier).set,
          showCourt: true,
        ),
        StrokeModelField(
          value: ref.watch(pendingJobOptionsProvider).strokeModel,
          health: ref.watch(healthProvider).valueOrNull,
          onChanged: ref.read(pendingJobOptionsProvider.notifier).setStrokeModel,
        ),
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
                            '(${next + 1} of 4), also for doubles.',
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
                        controller.start(
                          corners: List.of(_corners),
                          startScore: ref.read(liveStartScoreProvider),
                        );
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

class _LiveView extends ConsumerStatefulWidget {
  const _LiveView({required this.state});

  final LiveState state;

  @override
  ConsumerState<_LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends ConsumerState<_LiveView> {
  bool _coach = false;
  String? _coachPlayer;
  int? _reviewCallId;
  final _practiceCues = <String?, ({String text, int rally})>{};

  String _reviewLabel(LineCall call) => 'Rally ${call.rallyIndex + 1} · ${formatClock(call.timeS)}';

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final controller = ref.read(liveControllerProvider.notifier);
    final record = state.record;
    final frameIndex = state.frameIndex;
    final lastRally = record.rallies.lastOrNull;
    final decisionBusy = !controller.canDecide;
    final pendingReviews = record.lineCalls.where((call) => call.needsReview).toList()
      ..sort((a, b) {
        final byFrame = a.frame.compareTo(b.frame);
        return byFrame == 0 ? a.id.compareTo(b.id) : byFrame;
      });
    final selectedReview =
        pendingReviews.where((call) => call.id == _reviewCallId).firstOrNull ??
        pendingReviews.firstOrNull;
    // The server sends the updated call just before the score acknowledgment. Keep the
    // decision in view until the score arrives or reconnect refreshes the snapshot.
    final confirmingReview = state.phase == LivePhase.live && decisionBusy
        ? record.lineCalls
              .where((call) => call.id == controller.pendingReviewId && call.reviewed)
              .firstOrNull
        : null;
    final review = confirmingReview ?? selectedReview;
    final call = review ?? bannerCall(record, frameIndex);
    final size = state.size;
    final image = controller.analyzedImage;
    final capture = controller.captureSize;
    final aspect = capture == null ? 16 / 9 : capture.width / capture.height;
    final video = AspectRatio(
      aspectRatio: aspect,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Colors.black),
            Center(
              child: AspectRatio(
                aspectRatio: aspect,
                child: image == null || size == null
                    ? controller.source?.preview()
                    : Image.memory(
                        image,
                        key: ObjectKey(image),
                        fit: BoxFit.fill,
                        cacheWidth: size.width,
                        errorBuilder: (_, _, _) =>
                            controller.source?.preview() ?? const SizedBox.shrink(),
                        frameBuilder: (context, child, frame, _) {
                          if (frame == null) return const SizedBox.expand();
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              child,
                              CustomPaint(
                                painter: LiveOverlayPainter(
                                  size: size,
                                  trail: state.trail,
                                  players: state.players,
                                  colors: PlayerColors.of(context),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ),
            if (state.phase != LivePhase.live)
              ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Text(switch (state.phase) {
                    LivePhase.connecting => 'Connecting… the server may be loading its models',
                    LivePhase.reconnecting => 'Refreshing camera connection…',
                    LivePhase.stopping => 'Saving the session…',
                    _ => '',
                  }, style: const TextStyle(color: Colors.white, fontSize: 18)),
                ),
              ),
          ],
        ),
      ),
    );
    final controls = [
      SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: false, icon: Icon(Icons.sports), label: Text('Referee')),
          ButtonSegment(
            value: true,
            icon: Icon(Icons.record_voice_over_outlined),
            label: Text('Coach'),
          ),
        ],
        selected: {_coach},
        onSelectionChanged: (roles) => setState(() => _coach = roles.first),
      ),
      StatusStrip(
        rallyState: state.rallyState,
        speedKmh: state.speedKmh,
        peakSpeedKmh: state.peakSpeedKmh,
        strokeCount: state.strokesInRally,
      ),
      if (state.phase == LivePhase.reconnecting || (state.phase == LivePhase.live && decisionBusy))
        Semantics(
          liveRegion: true,
          child: Text(
            state.phase == LivePhase.reconnecting
                ? 'Reconnecting and refreshing the score…'
                : 'Waiting for the referee decision to be confirmed…',
          ),
        ),
      if (!_coach && pendingReviews.isNotEmpty)
        Text(
          '${pendingReviews.length} ${pendingReviews.length == 1 ? 'call' : 'calls'} awaiting review',
        ),
      if (!_coach && confirmingReview == null && selectedReview != null)
        if (pendingReviews.length == 1)
          Text(_reviewLabel(selectedReview))
        else
          DropdownButton<int>(
            key: const Key('live-review-queue'),
            isExpanded: true,
            value: selectedReview.id,
            onChanged: decisionBusy ? null : (id) => setState(() => _reviewCallId = id),
            items: [
              for (final review in pendingReviews)
                DropdownMenuItem(
                  value: review.id,
                  child: Text(_reviewLabel(review), overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
      if (!_coach && confirmingReview != null) Text(_reviewLabel(confirmingReview)),
      if (!_coach && call != null)
        LineCallBanner(
          call: call,
          onDecide: (decision) => controller.overrideCall(call.id, decision),
          busy: decisionBusy,
        ),
      Scoreboard(
        record: record,
        frameIndex: frameIndex,
        live: true,
        busy: !_coach && decisionBusy,
        showHistory: false,
        onAward: _coach ? null : controller.award,
        onUndo: _coach ? null : controller.undo,
        onSetService: _coach ? null : controller.setService,
        onClearLast: _coach || lastRally?.winner == null
            ? null
            : () => controller.correct(lastRally!.index, null),
      ),
    ];
    final details = _coach
        ? LiveCoachPanel(
            state: state,
            player: _coachPlayer,
            practiceCue: _practiceCues[_coachPlayer],
            onPracticeCueChanged: (cue) => setState(() {
              if (cue == null) {
                _practiceCues.remove(_coachPlayer);
              } else {
                _practiceCues[_coachPlayer] = cue;
              }
            }),
            onPlayerChanged: (player) => setState(() => _coachPlayer = player),
          )
        : SectionCard(
            title: 'Rally history',
            child: record.rallies.isEmpty
                ? const Text('Completed rallies appear here. Tap a selected winner to clear it.')
                : RallyHistory(
                    record: record,
                    frameIndex: frameIndex,
                    onCorrect: decisionBusy ? null : controller.correct,
                  ),
          );
    final camera = [
      video,
      LiveStatusBar(state: state),
      if (state.phase == LivePhase.live && controller.waitingForAnalysis)
        const Text('Waiting for a fresh analysis overlay…'),
      if (state.hits.isNotEmpty) HitCallout(hit: state.hits.last),
    ];
    final analysis = [
      CourtMinimap(record: record, frameIndex: frameIndex, reviewCall: _coach ? null : review),
      SectionCard(
        title: 'Recent strokes',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.hits.isEmpty) const Text('Detected strokes appear here during play.'),
            for (final hit in state.hits.reversed.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '${formatClock(hit.timeS)} · ${playerLabel(hit.who)}'
                  ' · ${kStrokeLabels[hit.stroke] ?? 'Unclassified'}',
                ),
              ),
            const Text('Open the saved replay to jump to a stroke.'),
          ],
        ),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget column(List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final child in children)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: child),
          ],
        );
        final wide = Breakpoints.forWidth(constraints.maxWidth) != WindowClass.compact;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: column([...controls, details])),
                    const SizedBox(width: 16),
                    Expanded(flex: 3, child: column([...camera, ...analysis])),
                  ],
                )
              : column([
                  ...controls,
                  if (_coach) details,
                  ...camera,
                  if (!_coach) details,
                  ...analysis,
                ]),
        );
      },
    );
  }
}
