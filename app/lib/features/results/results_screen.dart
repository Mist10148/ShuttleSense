import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/clip_record.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import 'widgets/court_minimap.dart';
import 'widgets/results_layout.dart';
import 'widgets/scoreboard.dart';
import 'widgets/status_strip.dart';
import 'widgets/stroke_timeline.dart';
import 'widgets/video_panel.dart';

/// C3 / FR-C3: annotated playback with timeline, minimap, status and score.
class ResultsScreen extends ConsumerWidget {
  const ResultsScreen({super.key, required this.jobId});

  final String jobId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final job = ref.watch(jobProvider(jobId));
    final record = ref.watch(recordProvider(jobId));
    final api = ref.watch(apiClientProvider);

    Future<void> open(String url) =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        actions: [
          // TODO(T5.11): share sheet on mobile and save dialog on desktop.
          PopupMenuButton<String>(
            tooltip: 'Download',
            icon: const Icon(Icons.download),
            onSelected: open,
            itemBuilder: (_) => [
              PopupMenuItem(value: api.videoUrl(jobId), child: const Text('Annotated video (MP4)')),
              PopupMenuItem(value: api.summaryUrl(jobId), child: const Text('Summary (JSON)')),
              PopupMenuItem(value: api.hitsCsvUrl(jobId), child: const Text('Hits (CSV)')),
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
          record: record,
          videoUrl: api.videoUrl(jobId),
          headers: api.authHeaders,
          videoAvailable: job.valueOrNull?.outputs.video ?? false,
        ),
      ),
    );
  }
}

class _ResultsBody extends StatefulWidget {
  const _ResultsBody({
    required this.record,
    required this.videoUrl,
    required this.headers,
    required this.videoAvailable,
  });

  final ClipRecord record;
  final String videoUrl;
  final Map<String, String> headers;
  final bool videoAvailable;

  @override
  State<_ResultsBody> createState() => _ResultsBodyState();
}

class _ResultsBodyState extends State<_ResultsBody> {
  late final Player _player = openPlayer(widget.videoUrl, widget.headers);
  late final VideoController _controller = VideoController(_player);

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    return StreamBuilder<Duration>(
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
          status: StatusStrip(
            rallyState: frame?.rallyState,
            speedKmh: frame?.shuttleSpeedKmh,
            peakSpeedKmh: record.summary?.peakSpeedKmh,
            strokeCount: record.hits.where((h) => h.frame <= frameIndex).length,
          ),
          timeline: StrokeTimeline(
            hits: record.hits,
            currentHitId: currentHit?.id,
            onSeek: _player.seek,
          ),
          minimap: CourtMinimap(frame: frame, calibrated: record.courtCorners != null),
          scoreboard: Scoreboard(score: record.score, summary: record.summary),
        );
      },
    );
  }
}

/// Lets other screens decide whether results exist for a job.
bool hasResults(Job job) => job.status == JobStatus.done && job.outputs.record;
