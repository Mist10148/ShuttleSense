import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';

const kStageLabels = {
  'io': 'Load video',
  'tracking': 'Track shuttle',
  'pose': 'Players and pose',
  'court': 'Court mapping',
  'hits': 'Detect hits',
  'strokes': 'Classify strokes',
  'feedback': 'Form feedback',
  'analytics': 'Speed and stats',
  'referee': 'Rally and score',
  'render': 'Render video',
};

/// "1 min 05 s", "42 s".
String formatDuration(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '$s s';
  return '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s';
}

/// C2 / FR-C2: per-stage job progress, then on to results.
class ProcessingScreen extends ConsumerWidget {
  const ProcessingScreen({super.key, required this.jobId});

  final String jobId;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel processing?'),
        content: const Text('The job stops and its partial results are deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel job'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(apiClientProvider).deleteJob(jobId);
    if (context.mounted) context.go(Routes.home);
  }

  Future<void> _retry(BuildContext context, WidgetRef ref, Job job) async {
    try {
      final next = await ref
          .read(apiClientProvider)
          .createJob(videoId: job.videoId, options: job.options, corners: job.courtCorners);
      if (context.mounted) context.go(Routes.job(next.id));
    } on Exception catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(jobProvider(jobId), (_, next) {
      if (next.valueOrNull?.status == JobStatus.done) context.go(Routes.results(jobId));
    });
    final job = ref.watch(jobProvider(jobId));

    return job.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Processing')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Processing')),
        body: MessageView(
          icon: Icons.wifi_off,
          message: 'Lost connection to server',
          detail: '$e\nThe job keeps running on the server.',
          action: FilledButton(
            onPressed: () => ref.invalidate(jobProvider(jobId)),
            child: const Text('Retry'),
          ),
        ),
      ),
      data: (job) => PageScaffold(
        title: 'Processing',
        actions: [
          if (!job.status.isFinished)
            TextButton(onPressed: () => _cancel(context, ref), child: const Text('Cancel')),
        ],
        children: [
          _Header(job: job),
          const SizedBox(height: 16),
          for (final stage in job.stages) _StageRow(stage: stage),
          if (job.status == JobStatus.failed) ...[
            const SizedBox(height: 16),
            Text(
              job.error ?? 'Processing failed',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _retry(context, ref, job),
                  icon: const Icon(Icons.replay),
                  label: const Text('Try again'),
                ),
                OutlinedButton(
                  onPressed: () => context.go(Routes.home),
                  child: const Text('Back to upload'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.job});

  final Job job;

  @override
  Widget build(BuildContext context) {
    final text = switch (job.status) {
      JobStatus.queued => 'Waiting in queue (position ${(job.queuePosition ?? 0) + 1})',
      JobStatus.running => 'Running: ${kStageLabels[job.currentStage] ?? job.currentStage ?? ''}',
      JobStatus.done => 'Done',
      JobStatus.failed => 'Failed',
      JobStatus.cancelled => 'Cancelled',
    };
    final elapsed = job.elapsed();
    final eta = job.eta();
    final timing = [
      if (elapsed != null) 'Elapsed ${formatDuration(elapsed)}',
      if (eta != null && job.status == JobStatus.running) 'about ${formatDuration(eta)} left',
    ].join(' · ');
    final percent = (job.progress * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(text, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Semantics(
          label: 'Overall progress',
          value: '$percent%',
          child: LinearProgressIndicator(
            value: job.status == JobStatus.queued ? null : job.progress,
          ),
        ),
        if (timing.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(timing, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({required this.stage});

  final StageState stage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (stage.status) {
      'done' => (Icons.check_circle, scheme.primary),
      'running' => (Icons.autorenew, scheme.tertiary),
      'failed' => (Icons.error, scheme.error),
      'skipped' => (Icons.remove_circle_outline, scheme.outline),
      _ => (Icons.radio_button_unchecked, scheme.outline),
    };
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: color),
      title: Text(kStageLabels[stage.name] ?? stage.name),
      subtitle: stage.status == 'running'
          ? LinearProgressIndicator(value: stage.progress == 0 ? null : stage.progress)
          : null,
      trailing: Text(stage.status, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
