import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/disclaimers.dart';
import '../../shared/widgets/match_setup_field.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';
import '../../shared/widgets/start_score_field.dart';
import '../../shared/widgets/stroke_model_field.dart';
import '../calibration/calibration_screen.dart';
import '../mode/mode_screen.dart';
import '../upload/upload_controller.dart';
import 'live_controller.dart';
import 'widgets/live_view.dart';

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
    // Leaving the screen mid-session would drop the socket without a stop (T12.6).
    return PopScope(
      canPop: !streaming,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && controller.canDecide) {
          confirmStop(context, state, controller.stop);
        }
      },
      child: _scaffold(context, state, controller, waiting: waiting, streaming: streaming),
    );
  }

  Widget _scaffold(
    BuildContext context,
    LiveState state,
    LiveController controller, {
    required bool waiting,
    required bool streaming,
  }) {
    final gutter = Breakpoints.gutter(Breakpoints.of(context));
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, Spacing.lg, gutter, 0),
          child: MaxWidth(
            maxWidth: 1400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: 'Live',
                  actions: [
                    if (waiting)
                      OutlinedButton.icon(
                        onPressed: controller.cancel,
                        icon: const Icon(Icons.close),
                        label: const Text('Cancel'),
                      )
                    else if (streaming)
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(context).colorScheme.onError,
                        ),
                        onPressed: controller.canDecide
                            ? () => confirmStop(context, state, controller.stop)
                            : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      )
                    else
                      const ChangeModeButton(),
                  ],
                ),
                const SizedBox(height: Spacing.md),
                Expanded(
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
                    _ => LiveView(state: state),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Stop saves and ends the session, which cannot be resumed afterwards: once rallies or
/// decisions exist, ask first (T12.6).
Future<void> confirmStop(BuildContext context, LiveState state, VoidCallback stop) async {
  final record = state.record;
  final worthAsking =
      record.rallies.isNotEmpty ||
      record.practiceGoals.isNotEmpty ||
      record.decisionLog.isNotEmpty ||
      (record.score?.corrections.isNotEmpty ?? false);
  if (!worthAsking) {
    stop();
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Stop and save this session?'),
      content: const Text(
        'The recording, score and calls are saved to History. The session cannot be '
        'continued afterwards.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep going')),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Stop and save'),
        ),
      ],
    ),
  );
  if (ok == true) stop();
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.state, required this.onRetry});

  final LiveState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MessageView(
      icon: state.permissionDenied ? Icons.no_photography_outlined : Icons.error_outline,
      message: state.error ?? 'Something went wrong',
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
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
    );
  }
}

class _ReadyView extends ConsumerWidget {
  const _ReadyView({required this.state});

  final LiveState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(liveControllerProvider.notifier);
    // The way to start comes first, right under the preview.
    final start = <Widget>[
      AppCard(
        padding: const EdgeInsets.all(Spacing.md),
        child: MaxWidthPreview(child: controller.source?.preview()),
      ),
      const SizedBox(height: Spacing.lg),
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
      if (state.error != null)
        Padding(
          padding: const EdgeInsets.only(top: Spacing.sm),
          child: Text(state.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
    ];
    final tips = AppCard(
      title: 'Before you start',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Put the ${state.cameraLabel.toLowerCase()} on a tripod, high and behind a '
            'baseline, with the whole court in view. Calibrate the court for the minimap, '
            'speed and line calls.',
          ),
          const Text('Without court calibration, player detection is disabled.'),
          const Text('For best accuracy, keep the camera fixed and do not pan or zoom.'),
          const SizedBox(height: Spacing.sm),
          Text(kLineCallNote, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
    final setup = AppCard(
      title: 'Match setup',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StartScoreField(
            value: ref.watch(liveStartScoreProvider),
            doubles: ref.watch(liveMatchSetupProvider).doubles,
            onChanged: (s) => ref.read(liveStartScoreProvider.notifier).state = s,
          ),
          MatchSetupField(
            value: ref.watch(liveMatchSetupProvider),
            onChanged: ref.read(liveMatchSetupProvider.notifier).set,
            showCourt: true,
            showChangeEnds: ref.watch(healthProvider).valueOrNull?.supportsChangeEnds ?? false,
          ),
          if (ref.watch(liveMatchSetupProvider).bestOf == 3 &&
              (ref.watch(healthProvider).valueOrNull?.supportsCourtside ?? false))
            StartGamesField(
              value: ref.watch(liveStartGamesProvider),
              doubles: ref.watch(liveMatchSetupProvider).doubles,
              onChanged: (g) => ref.read(liveStartGamesProvider.notifier).state = g,
            ),
          StrokeModelField(
            value: ref.watch(pendingJobOptionsProvider).strokeModel,
            health: ref.watch(healthProvider).valueOrNull,
            onChanged: ref.read(pendingJobOptionsProvider.notifier).setStrokeModel,
          ),
        ],
      ),
    );
    // Plain scroll views, so every field below the fold stays built.
    Widget scroll(List<Widget> children) => SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: Spacing.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
    const gap = SizedBox(height: Spacing.lg);
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < _kSidePanelMinWidth) {
          return scroll([...start, gap, tips, gap, setup]);
        }
        // Wide: the preview and start buttons on the left, setup beside them, in one scroll.
        Widget column(List<Widget> children) =>
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
        return scroll([
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: column(start)),
              const SizedBox(width: Spacing.xl),
              SizedBox(width: _kSidePanelWidth, child: column([setup, gap, tips])),
            ],
          ),
        ]);
      },
    );
  }
}

/// From this width the ready view puts match setup in a side panel next to the preview.
const _kSidePanelMinWidth = 840.0;
const _kSidePanelWidth = 380.0;

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
          padding: const EdgeInsets.all(Spacing.md),
          child: Row(
            children: [
              CornerDiagram(next: next),
              const SizedBox(width: Spacing.md),
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
          padding: const EdgeInsets.all(Spacing.md),
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
    return MessageView(
      icon: jobId == null ? Icons.videocam_off_outlined : Icons.check_circle_outline,
      message: jobId == null
          ? 'No frames reached the server, so nothing was saved.'
          : 'Session saved to History. The annotated video is rendering.',
      action: Wrap(
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
    );
  }
}
