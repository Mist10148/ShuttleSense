import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../data/repositories/analysis_repository.dart';
import '../../../shared/widgets/courtside_tools.dart';
import '../../../shared/widgets/hit_burst.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/surfaces.dart';
import '../../results/widgets/court_minimap.dart';
import '../../results/widgets/line_call_banner.dart';
import '../../results/widgets/scoreboard.dart';
import '../../results/widgets/status_strip.dart';
import '../../results/widgets/stroke_timeline.dart';
import '../live_controller.dart';
import '../live_screen.dart';
import '../../../shared/widgets/tactile.dart';

/// The running live session: camera, calls, scoreboard and coach panel (moved out of
/// live_screen.dart so each file stays readable).

class LiveView extends ConsumerStatefulWidget {
  const LiveView({super.key, required this.state});

  final LiveState state;

  @override
  ConsumerState<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends ConsumerState<LiveView> {
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
    final courtside = ref.watch(healthProvider).valueOrNull?.supportsCourtside ?? false;
    final changeEnds = ref.watch(healthProvider).valueOrNull?.supportsChangeEnds ?? false;
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
    final video = AppCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
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
              if (state.phase == LivePhase.live && state.hits.isNotEmpty)
                HitBurstLayer(
                  events: [
                    HitBurstEvent(
                      id: state.hits.last.id,
                      who: state.hits.last.who,
                      stroke: state.hits.last.uncertain ? null : state.hits.last.stroke,
                    ),
                  ],
                ),
              if (state.phase != LivePhase.live)
                ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Text(switch (state.phase) {
                      LivePhase.connecting => 'Connecting… the server may be loading its models',
                      LivePhase.reconnecting => 'Reconnecting…',
                      LivePhase.stopping => 'Saving the session…',
                      _ => '',
                    }, style: const TextStyle(color: Colors.white, fontSize: 18)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final scoreboard = Scoreboard(
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
      doubles: state.doubles,
      onAwardReason: _coach || !courtside
          ? null
          : (side, reason) => controller.award(side, reason: reason),
      onLet: _coach || !courtside || lastRally == null
          ? null
          : () => controller.correct(lastRally.index, null, reason: 'let'),
      onConcede: _coach || !courtside ? null : controller.concede,
      onSwapEnds: _coach || !changeEnds ? null : controller.swapEnds,
    );
    final controls = [
      DepthSegmented<bool>(
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
      // The match is decided: nothing more to score, so offer to save it (T12.6).
      if (state.phase == LivePhase.live && (record.score?.matchOver ?? false))
        AppCard(
          key: const Key('match-over'),
          color: AppPalette.of(context).mint,
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Match won by ${playerLabel(record.score!.matchWinner!)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (!_coach) const Text('Undo to change the result.'),
              const SizedBox(height: Spacing.sm),
              FilledButton(
                onPressed: decisionBusy ? null : () => confirmStop(context, state, controller.stop),
                child: const Text('Stop and save'),
              ),
            ],
          ),
        ),
      if (state.phase == LivePhase.stopping)
        Semantics(liveRegion: true, child: const Text('Saving the session to History…')),
      if (state.phase == LivePhase.reconnecting ||
          (state.phase == LivePhase.live && controller.pendingAction != null))
        Semantics(
          liveRegion: true,
          child: Text(
            state.phase == LivePhase.reconnecting
                ? 'Reconnecting and refreshing the score…'
                : controller.pendingAction!,
          ),
        ),
      if (!_coach) scoreboard,
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
    ];
    final savedGoal = state.practiceGoals.where((g) => g.player == _coachPlayer).firstOrNull;
    Future<void> editGoal() async {
      final goal = await editPracticeGoal(context, player: _coachPlayer, current: savedGoal);
      if (goal != null && mounted) controller.saveGoal(goal);
    }

    final goalControls = !state.courtsideDepth
        ? null
        : savedGoal == null
        ? Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: decisionBusy ? null : editGoal,
              icon: const Icon(Icons.flag_outlined),
              label: const Text('Set practice goal'),
            ),
          )
        : PracticeGoalCard(
            goal: savedGoal,
            onComplete: decisionBusy
                ? null
                : (done) => controller.saveGoal(savedGoal, completed: done),
            onEdit: decisionBusy ? null : editGoal,
          );
    final details = _coach
        ? LiveCoachPanel(
            state: state,
            player: _coachPlayer,
            goalControls: goalControls,
            practiceCue: state.courtsideDepth ? null : _practiceCues[_coachPlayer],
            onPracticeCueChanged: state.courtsideDepth
                ? (decisionBusy
                      ? null
                      : (cue) {
                          if (cue == null) return;
                          final rally = record.rallies
                              .where((r) => r.index == cue.rally)
                              .firstOrNull;
                          controller.saveGoal(
                            PracticeGoal(
                              text: cue.text,
                              player: _coachPlayer,
                              source: 'cue',
                              rally: cue.rally,
                              frame: rally?.endFrame,
                              timeS: rally == null ? null : rally.endFrame / state.fps,
                            ),
                          );
                        })
                : (cue) => setState(() {
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
                    doubles: state.doubles,
                    onCorrect: decisionBusy ? null : controller.correct,
                  ),
          );
    if (state.courtsideDepth) {
      if (!_coach && state.intervalState != null) {
        controls.add(
          IntervalPanel(
            interval: state.intervalState!,
            onAction: decisionBusy ? null : controller.interval,
          ),
        );
      }
      if (!_coach) controls.add(DecisionHistory(record: record));
    }
    final camera = [
      video,
      LiveStatusBar(state: state),
      if (state.phase == LivePhase.live && controller.waitingForAnalysis)
        const Text('Waiting for a fresh analysis overlay…'),
      if (state.hits.isNotEmpty) HitCallout(hit: state.hits.last),
    ];
    final analysis = [
      if (_coach) scoreboard,
      CourtMinimap(
        record: record,
        frameIndex: frameIndex,
        reviewCall: _coach ? null : review,
        live: true,
        rallyStart: state.rallyStartFrame,
        doubles: state.doubles,
      ),
      SectionCard(
        title: 'Recent strokes',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.hits.isEmpty) const Text('Detected strokes appear here during play.'),
            for (final hit in state.hits.reversed.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
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
    // Courtside keys on a laptop or tablet keyboard (T12.6): referee role only.
    final canKey = !_coach && state.phase == LivePhase.live && !decisionBusy;
    final scoreOpen = !(record.score?.matchOver ?? false);
    final keyed = call != null && call.needsReview ? call : null;
    final shortcuts = <ShortcutActivator, VoidCallback>{
      if (canKey && scoreOpen) ...{
        const SingleActivator(LogicalKeyboardKey.keyN): () => controller.award('near'),
        const SingleActivator(LogicalKeyboardKey.keyF): () => controller.award('far'),
      },
      if (canKey) ...{
        const SingleActivator(LogicalKeyboardKey.keyZ): controller.undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): controller.undo,
      },
      if (canKey && scoreOpen && courtside && lastRally != null)
        const SingleActivator(LogicalKeyboardKey.keyL): () =>
            controller.correct(lastRally.index, null, reason: 'let'),
      if (canKey && scoreOpen && changeEnds)
        const SingleActivator(LogicalKeyboardKey.keyE): controller.swapEnds,
      if (canKey && keyed != null) ...{
        const SingleActivator(LogicalKeyboardKey.keyI): () =>
            controller.overrideCall(keyed.id, 'in'),
        const SingleActivator(LogicalKeyboardKey.keyO): () =>
            controller.overrideCall(keyed.id, 'out'),
      },
    };
    return CallbackShortcuts(
      bindings: shortcuts.map(
        (key, action) => MapEntry(key, () {
          final focus = FocusManager.instance.primaryFocus?.context;
          if (focus?.findAncestorWidgetOfExactType<EditableText>() != null ||
              focus?.widget is EditableText) {
            return;
          }
          action();
        }),
      ),
      child: Focus(autofocus: true, child: _layout(controls, details, camera, analysis)),
    );
  }

  Widget _layout(
    List<Widget> controls,
    Widget details,
    List<Widget> camera,
    List<Widget> analysis,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget column(List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final child in children)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: child,
              ),
          ],
        );
        final wide = Breakpoints.forWidth(constraints.maxWidth) != WindowClass.compact;
        // The page around this view gives the side gutter.
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: Spacing.lg),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 2,
                      child: column([
                        ...controls,
                        details,
                        if (!_coach)
                          Text(
                            'Keys: N / F point near / far · Z undo · L let · I / O the call '
                            'under review',
                            key: const Key('live-keys'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ]),
                    ),
                    const SizedBox(width: Spacing.lg),
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
