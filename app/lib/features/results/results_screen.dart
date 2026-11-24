import '../../shared/widgets/courtside_tools.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/config/server_config.dart';
import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/health.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../core/responsive/breakpoints.dart';
import '../../shared/widgets/data_display.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../history/history_screen.dart' show formatJobDate;
import 'downloads.dart';
import 'widgets/court_minimap.dart';
import 'widgets/line_call_banner.dart';
import 'widgets/results_layout.dart';
import 'widgets/scoreboard.dart';
import 'widgets/session_summary.dart';
import 'widgets/shot_marker_bar.dart';
import 'widgets/player_cards.dart';
import 'widgets/shot_panel.dart';
import 'widgets/stroke_timeline.dart';
import 'widgets/summary_chart.dart';
import 'widgets/video_panel.dart';
import '../coach/coach_report_card.dart';
import '../../shared/widgets/hit_burst.dart';
import 'widgets/hit_anchor.dart';
import '../../core/theme/app_theme.dart';
import '../../shared/widgets/tactile.dart';
import '../../ui/depth.dart';

/// C3 / FR-C3: annotated playback with timeline, minimap, status and score.
class ResultsScreen extends ConsumerWidget {
  const ResultsScreen({super.key, required this.jobId});

  final String jobId;

  Future<void> _download(BuildContext context, WidgetRef ref, ExportFile file) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text('Preparing ${file.label}…')));
    try {
      final path = await saveExport(ref.read(apiClientProvider), jobId, file);
      messenger.hideCurrentSnackBar();
      if (path != null) messenger.showSnackBar(SnackBar(content: Text('Saved $path')));
    } on Exception catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // "Change server" clears the config; this tree may rebuild once before the redirect.
    if (ref.watch(serverConfigProvider) == null) return const SizedBox.shrink();
    final job = ref.watch(jobProvider(jobId));
    final record = ref.watch(recordProvider(jobId));
    final api = ref.watch(apiClientProvider);
    final outputs = job.valueOrNull?.outputs;

    final j = job.valueOrNull;
    final filename = j == null ? null : ref.watch(videoProvider(j.videoId)).valueOrNull?.filename;
    // The file is the title; what it is and when sits under it.
    final below = [
      'Results',
      if (j != null) ...[
        j.isLive ? 'Live' : 'Upload',
        if (j.court.isNotEmpty) '${j.court[0].toUpperCase()}${j.court.substring(1)}',
        formatJobDate(j.createdAt),
      ],
    ].join(' · ');
    final window = Breakpoints.of(context);
    final gutter = Breakpoints.gutter(window);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, Spacing.lg, gutter, Spacing.lg),
          child: MaxWidth(
            maxWidth: 1600,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: filename ?? 'Results',
                  dense: true,
                  below: below,
                  actions: _actions(context, ref, j, outputs),
                ),
                const SizedBox(height: Spacing.lg),
                Expanded(
                  // A failed refresh (e.g. after a score correction) keeps the results
                  // on screen.
                  child: record.when(
                    skipError: true,
                    loading: () => const _ResultsSkeleton(),
                    error: (e, _) => MessageView(
                      icon: Icons.error_outline,
                      message: 'Could not load results',
                      detail: '$e',
                      action: FilledButton(
                        onPressed: () => ref.invalidate(recordProvider(jobId)),
                        child: const Text('Try again'),
                      ),
                    ),
                    data: (record) => _ResultsBody(
                      jobId: jobId,
                      record: record,
                      videoUrl: api.videoUrl(jobId),
                      headers: api.authHeaders,
                      videoAvailable: outputs?.video,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context, WidgetRef ref, Job? job, JobOutputs? outputs) => [
    if (job case final Job j)
      Tooltip(
        message: 'Change overlays',
        child: OutlinedButton.icon(
          icon: const Icon(Icons.layers_outlined, size: 18),
          label: const Text('Overlays'),
          onPressed: () => showRerenderSheet(context, ref, j),
        ),
      ),
    PopupMenuButton<ExportFile>(
      tooltip: 'Download or share',
      onSelected: (file) => _download(context, ref, file),
      // A labelled key; the menu lists each file.
      child: IgnorePointer(
        child: OutlinedButton.icon(
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Download'),
          onPressed: () {},
        ),
      ),
      itemBuilder: (_) => [
        for (final file in ExportFile.values)
          PopupMenuItem(
            value: file,
            enabled: switch (file) {
              ExportFile.video => outputs?.video ?? true,
              ExportFile.summary => outputs?.summary ?? true,
              ExportFile.hitsCsv => outputs?.hitsCsv ?? true,
              ExportFile.ralliesCsv => outputs?.ralliesCsv ?? true,
            },
            child: Text(file.label),
          ),
      ],
    ),
  ];
}

/// The record's headline numbers; a number the record does not have gets no tile.
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.record});

  final ClipRecord record;

  @override
  Widget build(BuildContext context) {
    final summary = record.summary;
    final seconds = record.fps > 0 && record.numFrames > 0 ? record.numFrames / record.fps : null;
    final tiles = [
      if (summary != null)
        StatTile(label: 'Strokes', value: '${summary.totalHits}', icon: Icons.sports_tennis),
      if (record.rallies.isNotEmpty)
        StatTile(label: 'Rallies', value: '${record.rallies.length}', icon: Icons.repeat),
      if (summary?.peakSpeedKmh case final peak?)
        StatTile(label: 'Peak speed', value: '${peak.round()}', unit: 'km/h', icon: Icons.speed),
      if (seconds != null)
        StatTile(label: 'Clip length', value: formatClock(seconds), icon: Icons.timer_outlined),
    ];
    if (tiles.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 720 ? tiles.length : 2;
        final width = (box.maxWidth - Spacing.md * (columns - 1)) / columns;
        return Wrap(
          spacing: Spacing.md,
          runSpacing: Spacing.md,
          children: [
            for (final tile in tiles)
              SizedBox(
                width: width,
                // Recessed slots inside the tab's panel, not raised cards on a raised card.
                child: InsetBox(
                  radius: 14,
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.md),
                  child: tile,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Under the video: the shot marks (drag to scrub), the transport with the clock, the speed
/// menu, and a line call waiting for review.
class _StageControls extends StatelessWidget {
  const _StageControls({
    required this.record,
    required this.frameIndex,
    required this.fps,
    required this.target,
    required this.onSeek,
    required this.onScrub,
    required this.onPreviousShot,
    required this.onNextShot,
    this.banner,
  });

  final ClipRecord record;
  final int frameIndex;
  final double fps;

  /// Null without a video to play.
  final PlaybackTarget? target;
  final ValueChanged<Moment> onSeek;
  final ValueChanged<int> onScrub;
  final VoidCallback? onPreviousShot;
  final VoidCallback? onNextShot;
  final Widget? banner;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final total = record.numFrames > 0 ? record.numFrames / fps : null;
    final clock = Text.rich(
      TextSpan(
        text: formatClock(frameIndex / fps),
        children: [
          if (total != null)
            TextSpan(
              text: ' / ${formatClock(total)}',
              style: TextStyle(color: p.text3, fontWeight: FontWeight.w400),
            ),
        ],
      ),
      maxLines: 1,
      softWrap: false,
      style: kFigureStyle.copyWith(color: p.ink, fontSize: 16, fontWeight: FontWeight.w600),
    );
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: raisedGradient(TactileTokens.of(context)),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: TactileTokens.of(context).rim),
              boxShadow: raisedShadows(TactileTokens.of(context), depth: 0.6),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.sm, Spacing.sm, Spacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (record.hits.isNotEmpty || record.lineCalls.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.sm),
                      child: ShotMarkerBar(
                        record: record,
                        frameIndex: frameIndex,
                        onSeek: onSeek,
                        onScrub: onScrub,
                      ),
                    ),
                  if (target case final t?)
                    PlaybackControls(
                      target: t,
                      fps: fps,
                      onPreviousShot: onPreviousShot,
                      onNextShot: onNextShot,
                      clock: clock,
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                      child: Row(children: [clock]),
                    ),
                ],
              ),
            ),
          ),
          // A line call waiting for review slides in under the bar and out once decided.
          AnimatedSwitcher(
            duration: MediaQuery.maybeDisableAnimationsOf(context) ?? false
                ? Duration.zero
                : const Duration(milliseconds: 240),
            transitionBuilder: (child, animation) => SizeTransition(
              sizeFactor: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              axisAlignment: -1,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: banner ?? const SizedBox.shrink(key: ValueKey('no-call')),
          ),
        ],
      ),
    );
  }
}

/// Grey blocks in the shape of the results layout while the record loads.
class _ResultsSkeleton extends StatelessWidget {
  const _ResultsSkeleton();

  static const _fill = Skeleton(height: double.infinity, radius: Radii.lg, pulse: false);

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (Breakpoints.forWidth(box.maxWidth) == WindowClass.compact) {
        return const Column(
          children: [
            AspectRatio(aspectRatio: 16 / 9, child: _fill),
            SizedBox(height: Spacing.md),
            Skeleton(height: 40, radius: Radii.pill, pulse: false),
            SizedBox(height: Spacing.md),
            Expanded(child: _fill),
          ],
        );
      }
      // The stage (video beside the shot panel) over the sections.
      return const Column(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Expanded(flex: 3, child: _fill),
                SizedBox(width: Spacing.xl - Spacing.xs),
                Expanded(flex: 2, child: _fill),
              ],
            ),
          ),
          SizedBox(height: Spacing.lg),
          Expanded(flex: 2, child: _fill),
        ],
      );
    },
  );
}

/// T5.12: pick overlays and re-render the annotated video from cached results.
Future<void> showRerenderSheet(BuildContext context, WidgetRef ref, Job job) async {
  final chosen = await showModalBottomSheet<Set<String>>(
    context: context,
    showDragHandle: true,
    builder: (context) =>
        _OverlaySheet(options: job.options, health: ref.read(healthProvider).valueOrNull),
  );
  if (chosen == null || !context.mounted) return;
  // The screen may be gone when the request returns; the container outlives it.
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    await container.read(apiClientProvider).render(job.id, chosen);
    container.invalidate(jobProvider(job.id));
    if (context.mounted) context.go(Routes.job(job.id));
  } on Exception catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _OverlaySheet extends StatefulWidget {
  const _OverlaySheet({required this.options, required this.health});

  /// The job's own options: what it was calibrated for and whether the referee ran.
  final JobOptions options;
  final Health? health;

  @override
  State<_OverlaySheet> createState() => _OverlaySheetState();
}

class _OverlaySheetState extends State<_OverlaySheet> {
  late final Set<String> _selected = {...widget.options.overlays};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Spacing.xl, 0, Spacing.xl, Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Overlays', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final MapEntry(key: name, value: label) in kOverlays.entries)
                  if (overlayDisabledReason(name, widget.options, widget.health) case final reason?)
                    Tooltip(
                      message: reason,
                      child: FilterChip(label: Text(label), selected: false, onSelected: null),
                    )
                  else
                    FilterChip(
                      label: Text(label),
                      selected: _selected.contains(name),
                      onSelected: (on) =>
                          setState(() => on ? _selected.add(name) : _selected.remove(name)),
                    ),
              ],
            ),
            const SizedBox(height: Spacing.lg),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                widget.options.copyWith(overlays: _selected).submittable(widget.health).overlays,
              ),
              child: const Text('Re-render video'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultsBody extends ConsumerStatefulWidget {
  const _ResultsBody({
    required this.jobId,
    required this.record,
    required this.videoUrl,
    required this.headers,
    required this.videoAvailable,
  });

  final String jobId;
  final ClipRecord record;
  final String videoUrl;
  final Map<String, String> headers;

  /// Null until the job has loaded.
  final bool? videoAvailable;

  @override
  ConsumerState<_ResultsBody> createState() => _ResultsBodyState();
}

class _ResultsBodyState extends ConsumerState<_ResultsBody> {
  final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  late final PlaybackTarget _target = MediaKitTarget(_player);
  late ClipRecord _record = widget.record;
  bool _correcting = false;
  bool _opened = false;

  /// The timeline's filters, shown in the section tab row.
  final _timelineFilter = TimelineFilter();

  /// Current frame; the layout rebuilds when it changes, not on every position event.
  final ValueNotifier<int> _frameIndex = ValueNotifier(0);
  StreamSubscription<Duration>? _position;

  @override
  void initState() {
    super.initState();
    _openIfAvailable();
    _position = _player.stream.position.listen((p) => _frameIndex.value = _record.frameAt(p));
    // A citation tapped while the record was still loading: ref.listen in build only sees
    // later requests, so play this one once the body is on screen.
    final pending = ref.read(seekRequestProvider(widget.jobId));
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _seekMoment(pending);
        ref.read(seekRequestProvider(widget.jobId).notifier).state = null;
      });
    }
  }

  /// Only ask for the video once the job says it exists (no request for a missing file).
  void _openIfAvailable() {
    if (_opened || widget.videoAvailable != true) return;
    _opened = true;
    unawaited(
      openVideo(_player, widget.videoUrl, widget.headers).catchError((Object error) {
        debugPrint('Could not open the video: $error');
      }),
    );
  }

  @override
  void didUpdateWidget(_ResultsBody old) {
    super.didUpdateWidget(old);
    if (old.record != widget.record) _record = widget.record;
    _openIfAvailable();
  }

  /// F16: flip (or clear) a rally's winner on the server and show the re-scored rallies.
  Future<void> _correct(int rallyIndex, String? winner) =>
      _changeScore((api) => api.correctScore(widget.jobId, rallyIndex: rallyIndex, winner: winner));

  /// D21: a point the referee layer missed, at the playback position.
  Future<void> _award(String winner) =>
      _changeScore((api) => api.awardPoint(widget.jobId, winner: winner, frame: _frameIndex.value));

  /// D33: a point with its reason (a fault or service fault by the other side).
  Future<void> _awardReason(String winner, String reason) => _changeScore(
    (api) => api.awardPoint(widget.jobId, winner: winner, frame: _frameIndex.value, reason: reason),
  );

  /// D33: a let, so the rally at (or last before) the playback position is replayed.
  Future<void> _let() async {
    final rally = _record.rallyToReplay(_frameIndex.value);
    if (rally == null) {
      // Before the first rally: replaying "the last rally of the match" would be a guess.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No rally to replay yet. Move to the rally first.')),
      );
      return;
    }
    return _changeScore(
      (api) => api.correctScore(widget.jobId, rallyIndex: rally.index, winner: null, reason: 'let'),
    );
  }

  /// D33: the other side retired; [winner] wins the match at the playback position.
  Future<void> _concede(String winner) => _changeScore(
    (api) => api.concedeMatch(widget.jobId, winner: winner, frame: _frameIndex.value),
  );

  /// Clip record 1.7: the players changed ends at the playback position.
  Future<void> _swapEnds() =>
      _changeScore((api) => api.swapEnds(widget.jobId, frame: _frameIndex.value));

  Future<void> _undo() => _changeScore((api) => api.undoScore(widget.jobId));

  /// D23: who serves and receives first in a later doubles game.
  Future<void> _setService(int game, String serverId, String receiverId) => _changeScore(
    (api) =>
        api.setGameService(widget.jobId, game: game, serverId: serverId, receiverId: receiverId),
  );

  Future<void> _changeScore(Future<ScoreUpdate> Function(ApiClient api) change) async {
    setState(() => _correcting = true);
    try {
      final update = await change(ref.read(apiClientProvider));
      if (!mounted) return;
      setState(
        () => _record = _record.copyWith(
          rallies: update.rallies,
          score: update.score,
          // An undo can take back a line-call override (D32).
          lineCalls: update.lineCalls,
        ),
      );
      // The server also rebuilt summary.json; fetch the record again for the chart.
      ref.invalidate(recordProvider(widget.jobId));
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _correcting = false);
    }
  }

  /// Without an annotated video there is no player position to follow, so the timeline
  /// moves the minimap, status strip and scoreboard to the hit itself.
  void _seek(Hit hit) => _seekMoment(Moment(frame: hit.frame, timeS: hit.timeS));

  /// Same for any timeline moment (session notes, line calls, chat citations).
  void _seekMoment(Moment m) {
    if (widget.videoAvailable == true) {
      final target = m.position - kSeekLead;
      _player.seek(target.isNegative ? Duration.zero : target);
    } else {
      final last = _record.numFrames == 0 ? 0 : _record.numFrames - 1;
      _frameIndex.value = m.frame.clamp(0, last);
    }
  }

  /// Scrubbing the shot bar: straight to [frame], with no lead-in.
  void _scrub(int frame) {
    final last = _record.numFrames == 0 ? 0 : _record.numFrames - 1;
    final f = frame.clamp(0, last);
    if (widget.videoAvailable == true) {
      final fps = _record.fps == 0 ? 30.0 : _record.fps;
      _player.seek(frameMid(f, fps));
    } else {
      _frameIndex.value = f;
    }
  }

  /// Frames in the lead-in a seek to a stroke leaves before it.
  int get _leadFrames {
    final fps = _record.fps == 0 ? 30.0 : _record.fps;
    return (kSeekLead.inMicroseconds * fps / Duration.microsecondsPerSecond).ceil();
  }

  /// J: the stroke before the playback position (or the start of the current one).
  void _previousShot() {
    final now = _frameIndex.value;
    Hit? found;
    for (final h in _record.hits) {
      if (h.frame < now) found = h;
    }
    if (found != null) _seek(found);
  }

  /// L: the next stroke after the playback position.
  void _nextShot() {
    final now = _frameIndex.value + _leadFrames;
    for (final h in _record.hits) {
      if (h.frame > now) return _seek(h);
    }
  }

  /// F20: confirm or override a line call; the server re-scores and rebuilds the notes.
  Future<void> _decide(LineCall call, String decision) async {
    setState(() => _correcting = true);
    try {
      final update = await ref
          .read(apiClientProvider)
          .overrideLineCall(widget.jobId, call.id, decision);
      if (!mounted) return;
      setState(
        () => _record = _record.copyWith(
          lineCalls: update.lineCalls,
          rallies: update.rallies,
          score: update.score,
        ),
      );
      ref.invalidate(recordProvider(widget.jobId));
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _correcting = false);
    }
  }

  @override
  void dispose() {
    _position?.cancel();
    _frameIndex.dispose();
    _timelineFilter.dispose();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A chat citation asked to play a moment of this job.
    ref.listen(seekRequestProvider(widget.jobId), (_, moment) {
      if (moment == null) return;
      _seekMoment(moment);
      ref.read(seekRequestProvider(widget.jobId).notifier).state = null;
    });
    final health = ref.watch(healthProvider).valueOrNull;
    final chatAvailable = health?.chatAvailable ?? false;
    final courtside = health?.supportsCourtside ?? false;
    final doublesJob = ref.watch(jobProvider(widget.jobId)).valueOrNull?.court == 'doubles';
    final record = _record;
    final fps = record.fps == 0 ? 30.0 : record.fps;
    final chart = SummaryChart(
      summary: record.summary,
      strokeModel: record.strokeModel,
    ); // does not change with the frame
    final hasHits = record.hits.isNotEmpty;
    // Built once per record, not once per video frame: playback rebuilds the layout up to 30
    // times a second, and these do not change with the frame.
    final coach = SessionSummary(
      record: record,
      doubles: doublesJob,
      videoAvailable: widget.videoAvailable == true,
      onGoalChanged: record.atLeast(6)
          ? (goal, done) async {
              try {
                await ref
                    .read(apiClientProvider)
                    .savePracticeGoal(widget.jobId, goal, completed: done);
                ref.invalidate(recordProvider(widget.jobId));
              } on Exception catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Could not save goal: $e')));
                }
              }
            }
          : null,
      onSeek: _seekMoment,
      chatAvailable: chatAvailable,
      onAskCoach: () => context.go(Routes.chat(widget.jobId)),
      report: CoachReportCard(
        jobId: widget.jobId,
        fps: fps,
        onSeek: widget.videoAvailable == true ? _seekMoment : null,
      ),
    );
    final decisions = DecisionHistory(
      record: record,
      onSeek: widget.videoAvailable == true ? _seekMoment : null,
    );
    return PlaybackShortcuts(
      target: _target,
      fps: fps,
      onPreviousShot: hasHits ? _previousShot : null,
      onNextShot: hasHits ? _nextShot : null,
      child: ValueListenableBuilder<int>(
        valueListenable: _frameIndex,
        builder: (context, frameIndex, _) {
          final currentHit = record.hitAt(frameIndex);
          final call = bannerCall(record, frameIndex);
          return ResultsLayout(
            video: VideoPanel(
              controller: _controller,
              available: widget.videoAvailable,
              aspectRatio: record.height == 0 ? null : record.width / record.height,
              overlay: HitBurstLayer(
                events: hitBurstsAt(record, frameIndex),
                nowS: fps > 0 ? frameIndex / fps : null,
                session: record.clipId,
              ),
            ),
            status: _StageControls(
              record: record,
              frameIndex: frameIndex,
              fps: fps,
              onSeek: _seekMoment,
              onScrub: _scrub,
              target: widget.videoAvailable == true ? _target : null,
              onPreviousShot: hasHits ? _previousShot : null,
              onNextShot: hasHits ? _nextShot : null,
              banner: call == null
                  ? null
                  : LineCallBanner(
                      call: call,
                      busy: _correcting,
                      onDecide: (decision) => _decide(call, decision),
                    ),
            ),
            shot: ShotPanel(record: record, frameIndex: frameIndex),
            compactShot: ShotPanel(record: record, frameIndex: frameIndex, dense: true),
            players: PlayerCards(record: record, frameIndex: frameIndex),
            stats: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatsRow(record: record),
                const SizedBox(height: Spacing.lg),
                chart,
              ],
            ),
            timeline: StrokeTimeline(
              hits: record.hits,
              currentHitId: currentHit?.id,
              onSeek: _seek,
              filter: _timelineFilter,
            ),
            timelineActions: record.hits.isEmpty
                ? null
                : TimelineFilters(filter: _timelineFilter, hits: record.hits),
            minimap: CourtMinimap(record: record, frameIndex: frameIndex),
            scoreboard: Column(
              children: [
                Scoreboard(
                  framed: false,
                  record: record,
                  frameIndex: frameIndex,
                  busy: _correcting,
                  onCorrect: _correct,
                  onAward: _award,
                  onUndo: _undo,
                  onSetService: _setService,
                  doubles: doublesJob,
                  onAwardReason: courtside ? _awardReason : null,
                  onLet: courtside && record.rallies.isNotEmpty ? _let : null,
                  onConcede: courtside ? _concede : null,
                  onSwapEnds: (health?.supportsChangeEnds ?? false) ? _swapEnds : null,
                ),
                decisions,
              ],
            ),
            coach: coach,
          );
        },
      ),
    );
  }
}

/// Lets other screens decide whether results exist for a job.
/// A finished job, or a saved live session whose video failed to render: its record (line
/// calls, score, notes) is complete, only the annotated video is missing.
bool hasResults(Job job) =>
    job.outputs.record &&
    (job.status == JobStatus.done || (job.isLive && job.status == JobStatus.failed));
