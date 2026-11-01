import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/config/server_config.dart';
import '../../core/router/app_router.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/health.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import 'downloads.dart';
import 'widgets/court_minimap.dart';
import 'widgets/line_call_banner.dart';
import 'widgets/results_layout.dart';
import 'widgets/scoreboard.dart';
import 'widgets/session_summary.dart';
import 'widgets/status_strip.dart';
import 'widgets/stroke_timeline.dart';
import 'widgets/summary_chart.dart';
import 'widgets/video_panel.dart';

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        actions: [
          if (job.valueOrNull case final Job j)
            IconButton(
              tooltip: 'Change overlays',
              icon: const Icon(Icons.layers_outlined),
              onPressed: () => showRerenderSheet(context, ref, j),
            ),
          PopupMenuButton<ExportFile>(
            tooltip: 'Download or share',
            icon: const Icon(Icons.download),
            onSelected: (file) => _download(context, ref, file),
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
        ],
      ),
      // A failed refresh (e.g. after a score correction) keeps the results on screen.
      body: record.when(
        skipError: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => MessageView(
          icon: Icons.error_outline,
          message: 'Could not load results',
          detail: '$e',
          action: FilledButton(
            onPressed: () => ref.invalidate(recordProvider(jobId)),
            child: const Text('Retry'),
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
    );
  }
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
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Overlays', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
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
            const SizedBox(height: 16),
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
    openVideo(_player, widget.videoUrl, widget.headers);
  }

  @override
  void didUpdateWidget(_ResultsBody old) {
    super.didUpdateWidget(old);
    if (old.record != widget.record) _record = widget.record;
    _openIfAvailable();
  }

  /// F16: flip a rally's winner on the server and show the re-scored rallies.
  Future<void> _correct(int rallyIndex, String winner) async {
    setState(() => _correcting = true);
    try {
      final update = await ref
          .read(apiClientProvider)
          .correctScore(widget.jobId, rallyIndex: rallyIndex, winner: winner);
      if (!mounted) return;
      setState(() => _record = _record.copyWith(rallies: update.rallies, score: update.score));
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
    final chatAvailable = ref.watch(healthProvider).valueOrNull?.chatAvailable ?? false;
    final record = _record;
    final fps = record.fps == 0 ? 30.0 : record.fps;
    final chart = SummaryChart(summary: record.summary); // does not change with the frame
    return PlaybackShortcuts(
      target: _target,
      fps: fps,
      child: ValueListenableBuilder<int>(
        valueListenable: _frameIndex,
        builder: (context, frameIndex, _) {
          final frame = record.frame(frameIndex);
          final currentHit = record.hitAt(frameIndex);
          final call = bannerCall(record, frameIndex);
          return ResultsLayout(
            video: VideoPanel(
              controller: _controller,
              available: widget.videoAvailable,
              aspectRatio: record.height == 0 ? null : record.width / record.height,
            ),
            status: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.videoAvailable == true) PlaybackControls(target: _target, fps: fps),
                StatusStrip(
                  rallyState: frame?.rallyState,
                  speedKmh: frame?.shuttleSpeedKmh,
                  peakSpeedKmh: record.summary?.peakSpeedKmh,
                  strokeCount: record.strokesSoFar(frameIndex),
                ),
                if (call != null)
                  LineCallBanner(
                    call: call,
                    busy: _correcting,
                    onDecide: (decision) => _decide(call, decision),
                  ),
              ],
            ),
            timeline: StrokeTimeline(
              hits: record.hits,
              currentHitId: currentHit?.id,
              onSeek: _seek,
            ),
            minimap: CourtMinimap(record: record, frameIndex: frameIndex),
            scoreboard: Column(
              children: [
                Scoreboard(
                  record: record,
                  frameIndex: frameIndex,
                  busy: _correcting,
                  onCorrect: _correct,
                ),
                const SizedBox(height: 16),
                chart,
              ],
            ),
            coach: SessionSummary(
              record: record,
              onSeek: _seekMoment,
              chatAvailable: chatAvailable,
              onAskCoach: () => context.go(Routes.chat(widget.jobId)),
            ),
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
