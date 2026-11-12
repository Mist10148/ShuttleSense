import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/clip_record.dart';
import '../../shared/disclaimers.dart';
import '../../shared/widgets/match_setup_field.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/section_card.dart';
import '../../shared/widgets/start_score_field.dart';
import '../calibration/calibration_screen.dart';
import '../mode/mode_screen.dart';
import '../results/widgets/court_minimap.dart';
import '../results/widgets/line_call_banner.dart';
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
        MatchSetupField(
          value: ref.watch(liveMatchSetupProvider),
          onChanged: ref.read(liveMatchSetupProvider.notifier).set,
          showCourt: true,
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
      Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text('Referee'),
            selected: !_coach,
            onSelected: (_) => setState(() => _coach = false),
          ),
          ChoiceChip(
            label: const Text('Coach'),
            selected: _coach,
            onSelected: (_) => setState(() => _coach = true),
          ),
        ],
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
                  '${formatClock(hit.timeS)} · ${hit.player == 'near' ? 'Near' : 'Far'}'
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

/// The newest hit: stroke, player and speed, the live "callout".
class HitCallout extends StatelessWidget {
  const HitCallout({super.key, required this.hit});

  final Hit hit;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final stroke = kStrokeLabels[hit.stroke] ?? 'Hit';
    final speed = hit.speedKmh == null ? '' : ' · ${hit.speedKmh!.round()} km/h (est.)';
    final side = hit.player == 'near' ? 'Near' : 'Far';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(Icons.bolt, color: colors.forSide(hit.player), size: 20),
            const SizedBox(width: 4),
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

/// Between-rally coaching (F21): what the last rally showed and the running top fixes,
/// from the server's `coaching` events. Chat opens once the session is saved.
class LiveCoachPanel extends StatelessWidget {
  const LiveCoachPanel({
    super.key,
    required this.state,
    this.player,
    this.onPlayerChanged,
    this.practiceCue,
    this.onPracticeCueChanged,
  });

  final LiveState state;
  final String? player;
  final ValueChanged<String?>? onPlayerChanged;
  final ({String text, int rally})? practiceCue;
  final ValueChanged<({String text, int rally})?>? onPracticeCueChanged;

  Widget _pinButton(String text, int rally) {
    final cue = (text: text, rally: rally);
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: cue == practiceCue ? null : () => onPracticeCueChanged?.call(cue),
        icon: const Icon(Icons.push_pin_outlined),
        label: Text(cue == practiceCue ? 'Pinned' : 'Pin cue'),
      ),
    );
  }

  List<SessionNote> _topFixes(Coaching? coaching) {
    if (coaching == null) return const [];
    if (player == null) return coaching.topFixes.take(3).toList();
    final notes = coaching.notes.where((note) => note.player == null || note.player == player);
    final ranked = notes.toList()
      ..sort((a, b) {
        final impact = (b.count * b.severity).compareTo(a.count * a.severity);
        if (impact != 0) return impact;
        final frequency = (b.count / b.total).compareTo(a.count / a.total);
        return frequency == 0 ? a.id.compareTo(b.id) : frequency;
      });
    return ranked.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = state.lastRally;
    final nextCue = _nextCue(last);
    final top = _topFixes(state.coaching);
    final side = player == 'near' ? 'Near' : 'Far';
    return SectionCard(
      title: 'Between-rally coaching',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onPlayerChanged != null)
            Wrap(
              spacing: 8,
              children: [
                for (final (value, label) in [(null, 'Both'), ('near', 'Near'), ('far', 'Far')])
                  ChoiceChip(
                    label: Text(label),
                    selected: player == value,
                    onSelected: (_) => onPlayerChanged!(value),
                  ),
              ],
            ),
          if (practiceCue case final cue?) ...[
            Text('Pinned practice cue · Rally ${cue.rally + 1}', style: theme.textTheme.titleSmall),
            Text(cue.text, style: theme.textTheme.titleMedium),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => onPracticeCueChanged?.call(null),
                child: const Text('Clear pin'),
              ),
            ),
            const Divider(height: 20),
          ],
          Text('Next rally', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            nextCue ??
                (last == null
                    ? 'Notes appear here after each rally.'
                    : player == null
                    ? 'Waiting for enough footage to suggest a cue.'
                    : 'Waiting for enough footage to suggest a cue for $side.'),
            style: theme.textTheme.titleMedium,
          ),
          if (last != null && nextCue != null && onPracticeCueChanged != null)
            _pinButton(nextCue, last.index),
          if (last != null) ...[
            const Divider(height: 20),
            Text('Last rally', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              [
                'Rally ${last.index + 1}',
                '${last.strokes} strokes',
                if (last.durationS != null) '${last.durationS!.toStringAsFixed(1)} s',
                if (last.peakSpeedKmh != null) 'peak ${last.peakSpeedKmh!.round()} km/h (est.)',
                if (last.call != null) 'landed ${last.call}',
                if (last.winner != null) '${last.winner == 'near' ? 'Near' : 'Far'} won',
              ].join(' · '),
            ),
          ],
          if (top.isNotEmpty) ...[
            const Divider(height: 20),
            Text('Focus so far', style: theme.textTheme.titleSmall),
            for (final (i, note) in top.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${i + 1}. ${note.text}'),
              ),
          ],
          if (state.rallies.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              title: const Text('Recent completed rallies'),
              children: [
                for (final rally in state.rallies.reversed.take(3))
                  Builder(builder: (context) => _recentRally(context, rally)),
              ],
            ),
          const SizedBox(height: 8),
          Text(kCoachingDisclaimer, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _recentRally(BuildContext context, Rally rally) {
    final hits = state.hits.reversed
        .skipWhile((hit) => hit.frame > rally.endFrame)
        .takeWhile((hit) => hit.frame >= rally.startFrame);
    String? cue;
    for (final hit in hits) {
      if (player != null && hit.player != player) continue;
      cue = _formatCue(hit.player, hit.stroke, hit.tip);
      if (cue != null) break;
    }
    final count = rally.strokeCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rally ${rally.index + 1} \u00b7 $count ${count == 1 ? 'stroke' : 'strokes'}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (cue != null) ...[
            Text(cue),
            if (onPracticeCueChanged != null) _pinButton(cue, rally.index),
          ],
        ],
      ),
    );
  }

  String? _nextCue(RallySummary? rally) {
    if (rally == null) return null;
    for (final fault in rally.faults) {
      if (player != null && fault.player != player) continue;
      final cue = _formatCue(fault.player, fault.stroke, fault.tip);
      if (cue != null) return cue;
    }
    return null;
  }

  String? _formatCue(String player, String? stroke, String? tip) {
    if (tip == null || tip.trim().isEmpty) return null;
    final side = player == 'near' ? 'Near' : 'Far';
    final who = stroke == null ? side : '$side, ${kStrokeLabels[stroke] ?? stroke}';
    return '$who: ${tip.trim()}';
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
