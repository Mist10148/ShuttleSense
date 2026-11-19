import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/notifications/job_notifier.dart';
import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/data_display.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';
import '../../core/theme/tokens.dart';
import '../results/results_screen.dart' show hasResults;

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
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(apiClientProvider).deleteJob(jobId);
      if (context.mounted) context.go(Routes.home);
    } on Exception catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not cancel: $e')));
      }
    }
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
    // Ask for notification permission while the app is in front (T4.4).
    if (ref.watch(notifyWhenDoneProvider)) unawaited(ref.read(jobNotifierProvider).prepare());
    ref.listen(jobProvider(jobId), (prev, next) {
      // The job finished while the app was in the background: say so (T4.4, T10.4).
      final was = prev?.valueOrNull?.status, now = next.valueOrNull?.status;
      if (was != null &&
          !was.isFinished &&
          (now == JobStatus.done || now == JobStatus.failed) &&
          ref.read(notifyWhenDoneProvider) &&
          ref.read(appInBackgroundProvider)()) {
        unawaited(
          ref.read(jobNotifierProvider).jobFinished(jobId: jobId, ok: now == JobStatus.done),
        );
      }
      // Only a fresh poll counts: after a re-render the provider is invalidated and, while it
      // reloads, still holds the old "done" job, which must not send the user back to the
      // old results.
      if (next.isLoading || next.valueOrNull?.status != JobStatus.done) return;
      if (prev?.valueOrNull?.status == JobStatus.done && prev?.isLoading == false) return;
      context.go(Routes.results(jobId));
    });
    final job = ref.watch(jobProvider(jobId));

    return job.when(
      loading: () => const PageScaffold(
        title: 'Processing',
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Skeleton(width: 220, height: 20, pulse: false),
                SizedBox(height: Spacing.lg),
                Skeleton(height: 8, pulse: false),
                SizedBox(height: Spacing.xl),
                Skeleton(pulse: false),
                SizedBox(height: Spacing.md),
                Skeleton(pulse: false),
                SizedBox(height: Spacing.md),
                Skeleton(pulse: false),
              ],
            ),
          ),
        ],
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Processing')),
        body: e is ApiException && e.statusCode == 404
            ? MessageView(
                icon: Icons.search_off,
                message: 'This job no longer exists',
                detail: 'It was cancelled or deleted.',
                action: FilledButton(
                  onPressed: () => context.go(Routes.home),
                  child: const Text('Back to upload'),
                ),
              )
            : MessageView(
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
        children: [
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  job: job,
                  cancel: job.status.isFinished
                      ? null
                      : OutlinedButton(
                          onPressed: () => _cancel(context, ref),
                          child: const Text('Cancel'),
                        ),
                ),
                ..._outcome(context, ref, job),
                const SizedBox(height: Spacing.lg),
                for (final stage in job.stages) _StageRow(stage: stage),
                if (!job.status.isFinished) ...[
                  const SizedBox(height: Spacing.sm),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Notify me when done'),
                    subtitle: const Text('If the app is in the background when the job ends'),
                    value: ref.watch(notifyWhenDoneProvider),
                    onChanged: (on) => ref.read(notifyWhenDoneProvider.notifier).set(on),
                  ),
                ],
              ],
            ),
          ),
          if (!job.status.isFinished) ...[
            const SizedBox(height: Spacing.xl),
            const _ResultsPreview(),
          ],
        ],
      ),
    );
  }

  /// What can be done once the job has ended: open the results, retry, or go back.
  List<Widget> _outcome(BuildContext context, WidgetRef ref, Job job) => [
    if (job.status == JobStatus.done) ...[
      // Reached with Back from the results screen.
      const SizedBox(height: Spacing.lg),
      FilledButton.icon(
        onPressed: () => context.go(Routes.results(jobId)),
        icon: const Icon(Icons.insights),
        label: const Text('View results'),
      ),
    ],
    if (job.status == JobStatus.cancelled) ...[
      const SizedBox(height: Spacing.lg),
      OutlinedButton(onPressed: () => context.go(Routes.home), child: const Text('Back to upload')),
    ],
    if (job.status == JobStatus.failed) ...[
      const SizedBox(height: Spacing.lg),
      Text(
        job.error ?? 'Processing failed',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
      const SizedBox(height: Spacing.sm),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          // A live session cannot be processed again as an upload (its overrides and
          // corrections belong to the live rallies), but its record is there.
          if (hasResults(job))
            FilledButton.icon(
              onPressed: () => context.go(Routes.results(jobId)),
              icon: const Icon(Icons.insights),
              label: const Text('View results'),
            )
          else
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
  ];
}

/// Where the results will appear, as still placeholder blocks while the job runs.
class _ResultsPreview extends StatelessWidget {
  const _ResultsPreview();

  @override
  Widget build(BuildContext context) => AppCard(
    title: 'Results',
    subtitle: 'Ready when processing finishes',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: Spacing.md),
              const Expanded(child: Skeleton(height: 64, radius: Radii.md, pulse: false)),
            ],
          ],
        ),
        const SizedBox(height: Spacing.lg),
        const Skeleton(height: 160, radius: Radii.md, pulse: false),
        const SizedBox(height: Spacing.lg),
        const Skeleton(width: 240, pulse: false),
      ],
    ),
  );
}

class _Header extends ConsumerWidget {
  const _Header({required this.job, required this.cancel});

  final Job job;

  /// The Cancel button while the job can still be stopped.
  final Widget? cancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AppPalette.of(context);
    final theme = Theme.of(context);
    final name = ref.watch(videoProvider(job.videoId)).valueOrNull?.filename;
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
      // A queued re-render may still carry the first run's start (servers before the fix).
      if (elapsed != null && job.status != JobStatus.queued) 'Elapsed ${formatDuration(elapsed)}',
      if (eta != null && job.status == JobStatus.running) 'about ${formatDuration(eta)} left',
    ].join(' · ');
    final percent = (job.progress * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconChip(icon: job.isLive ? Icons.videocam_outlined : Icons.movie_outlined),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name ?? (job.isLive ? 'Live session' : 'Analysis'),
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: p.text2)),
                ],
              ),
            ),
            Text('$percent%', style: theme.textTheme.titleMedium),
            if (cancel != null) ...[const SizedBox(width: Spacing.md), cancel!],
          ],
        ),
        const SizedBox(height: Spacing.lg),
        GradientProgress(value: job.progress, label: 'Overall progress'),
        if (timing.isNotEmpty) ...[
          const SizedBox(height: Spacing.sm),
          Text(timing, style: theme.textTheme.bodySmall),
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
      'done' => (Icons.check_circle, AppPalette.of(context).brand),
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
          ? Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: GradientProgress(value: stage.progress, height: 4),
            )
          : null,
      trailing: Text(stage.status, style: Theme.of(context).textTheme.labelSmall),
    );
  }
}
