import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/router/app_router.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import 'downloads.dart';
import 'widgets/court_minimap.dart';
import 'widgets/results_layout.dart';
import 'widgets/scoreboard.dart';
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
                    ExportFile.ralliesCsv => outputs?.ralliesCsv ?? true,
                    _ => true,
                  },
                  child: Text(file.label),
                ),
            ],
          ),
        ],
      ),
      body: record.when(
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
          videoAvailable: outputs?.video ?? false,
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
        _OverlaySheet(initial: job.overlays.toSet(), calibrated: job.courtCorners != null),
  );
  if (chosen == null || !context.mounted) return;
  try {
    await ref.read(apiClientProvider).render(job.id, chosen);
    ref.invalidate(jobProvider(job.id));
    if (context.mounted) context.go(Routes.job(job.id));
  } on Exception catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _OverlaySheet extends StatefulWidget {
  const _OverlaySheet({required this.initial, required this.calibrated});

  final Set<String> initial;
  final bool calibrated;

  @override
  State<_OverlaySheet> createState() => _OverlaySheetState();
}

class _OverlaySheetState extends State<_OverlaySheet> {
  late final Set<String> _selected = {...widget.initial};

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
                  FilterChip(
                    label: Text(label),
                    selected: _selected.contains(name),
                    onSelected: !widget.calibrated && kCourtOverlays.contains(name)
                        ? null
                        : (on) => setState(() => on ? _selected.add(name) : _selected.remove(name)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, _selected),
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
  final bool videoAvailable;

  @override
  ConsumerState<_ResultsBody> createState() => _ResultsBodyState();
}

class _ResultsBodyState extends ConsumerState<_ResultsBody> {
  late final Player _player = openPlayer(widget.videoUrl, widget.headers);
  late final VideoController _controller = VideoController(_player);
  late final PlaybackTarget _target = MediaKitTarget(_player);
  late ClipRecord _record = widget.record;
  bool _correcting = false;

  @override
  void didUpdateWidget(_ResultsBody old) {
    super.didUpdateWidget(old);
    if (old.record != widget.record) _record = widget.record;
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
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = _record;
    final fps = record.fps == 0 ? 30.0 : record.fps;
    return PlaybackShortcuts(
      target: _target,
      fps: fps,
      child: StreamBuilder<Duration>(
        stream: _player.stream.position,
        initialData: Duration.zero,
        builder: (context, snapshot) {
          final frameIndex = record.frameAt(snapshot.data ?? Duration.zero);
          final frame = record.frame(frameIndex);
          final currentHit = record.hitAt(frameIndex);
          return ResultsLayout(
            video: VideoPanel(
              controller: _controller,
              available: widget.videoAvailable,
              aspectRatio: record.height == 0 ? null : record.width / record.height,
            ),
            status: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.videoAvailable) PlaybackControls(target: _target, fps: fps),
                StatusStrip(
                  rallyState: frame?.rallyState,
                  speedKmh: frame?.shuttleSpeedKmh,
                  peakSpeedKmh: record.summary?.peakSpeedKmh,
                  strokeCount: record.strokesSoFar(frameIndex),
                ),
              ],
            ),
            timeline: StrokeTimeline(
              hits: record.hits,
              currentHitId: currentHit?.id,
              onSeek: _player.seek,
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
                SummaryChart(summary: record.summary),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Lets other screens decide whether results exist for a job.
bool hasResults(Job job) => job.status == JobStatus.done && job.outputs.record;
