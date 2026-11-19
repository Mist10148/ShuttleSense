import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_mode.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/data_display.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';
import '../history/history_screen.dart';
import '../mode/mode_screen.dart';
import '../results/results_screen.dart' show hasResults;

/// How many analyses "Recent analyses" lists.
const _kRecent = 5;

/// The landing page: start an analysis, the latest analyses, and the stroke mix of the last
/// finished one. Before the first analysis it shows a welcome and a camera tip instead.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = [...?ref.watch(jobsListProvider).valueOrNull]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final latestDone = jobs.where(hasResults).firstOrNull;
    return PageScaffold(
      title: 'Home',
      showBack: false,
      maxWidth: 1200,
      children: [
        const AppCard(title: 'Start an analysis', child: ModeChoices()),
        const SizedBox(height: Spacing.lg),
        CardGrid(
          children: [
            if (jobs.isEmpty)
              const _FirstRun()
            else
              _RecentAnalyses(jobs: jobs.take(_kRecent).toList()),
            if (latestDone != null) _StrokeMix(job: latestDone),
            if (jobs.isEmpty || latestDone == null) const _CameraTip(),
          ],
        ),
      ],
    );
  }
}

/// No analyses on this server yet: say what Home will show and offer the first upload.
class _FirstRun extends ConsumerWidget {
  const _FirstRun();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AppCard(
    child: MessageView(
      icon: Icons.sports_tennis,
      message: 'No analyses yet',
      detail: 'Your latest analyses and their stroke mix show up here.',
      action: FilledButton.icon(
        onPressed: () async {
          await ref.read(appModeProvider.notifier).set(AppMode.upload);
          if (context.mounted) context.go(Routes.home);
        },
        icon: const Icon(Icons.upload_file),
        label: const Text('Upload your first rally'),
      ),
    ),
  );
}

class _CameraTip extends StatelessWidget {
  const _CameraTip();

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return AppCard(
      color: p.peach,
      title: 'Camera setup',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const IconChip(icon: Icons.videocam_outlined),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Text(
              'Put the phone on a tripod, raised and behind the baseline, with the whole court '
              'in frame. Keep it still for the whole rally.',
              style: text.bodyMedium?.copyWith(color: p.text2),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentAnalyses extends StatelessWidget {
  const _RecentAnalyses({required this.jobs});

  final List<Job> jobs;

  @override
  Widget build(BuildContext context) => AppCard(
    title: 'Recent analyses',
    subtitle: 'Newest first',
    onExpand: () => context.go(Routes.history),
    padding: const EdgeInsets.fromLTRB(Spacing.xl, Spacing.xl, Spacing.md, Spacing.md),
    child: Column(children: [for (final job in jobs) _RecentRow(job: job)]),
  );
}

class _RecentRow extends ConsumerWidget {
  const _RecentRow({required this.job});

  final Job job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AppPalette.of(context);
    final name = ref.watch(videoProvider(job.videoId)).valueOrNull?.filename;
    final running = !job.status.isFinished;
    return ListRow(
      leading: IconChip(
        icon: job.isLive ? Icons.videocam_outlined : Icons.movie_outlined,
        background: job.isLive ? p.sky : p.lavender,
      ),
      title: name ?? (job.isLive ? 'Live session' : 'Analysis'),
      subtitle: '${job.isLive ? 'Live' : 'Upload'} · ${formatJobDate(job.createdAt)}',
      trailing: running
          ? SizedBox(
              width: 88,
              child: GradientProgress(value: job.progress, label: 'Processing'),
            )
          : jobStatusPill(job),
      onTap: () => context.go(hasResults(job) ? Routes.results(job.id) : Routes.job(job.id)),
    );
  }
}

/// Strokes of the latest finished analysis, by type, as labelled bars.
class _StrokeMix extends ConsumerWidget {
  const _StrokeMix({required this.job});

  final Job job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final counts = ref.watch(recordProvider(job.id)).valueOrNull?.summary?.strokeCounts;
    final name = ref.watch(videoProvider(job.videoId)).valueOrNull?.filename;
    final types = [
      for (final type in kStrokeLabels.keys)
        if ((counts?[type] ?? 0) > 0) type,
    ];
    final total = types.fold<int>(0, (sum, t) => sum + counts![t]!);
    return AppCard(
      title: 'Stroke mix',
      subtitle: 'Latest analysis${name == null ? '' : ' · $name'}',
      onExpand: () => context.go(Routes.results(job.id)),
      child: counts == null
          ? const Column(
              children: [
                Skeleton(),
                SizedBox(height: Spacing.md),
                Skeleton(),
                SizedBox(height: Spacing.md),
                Skeleton(),
              ],
            )
          : total == 0
          ? Text('No strokes were named in this analysis.', style: text.bodySmall)
          : Column(
              children: [
                for (final (i, type) in types.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.md),
                    child: Semantics(
                      label: '${kStrokeLabels[type]}: ${counts[type]} of $total strokes',
                      excludeSemantics: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(kStrokeLabels[type]!, style: text.bodyMedium)),
                              Text(
                                '${counts[type]} · ${(counts[type]! * 100 / total).round()}%',
                                style: text.bodySmall?.copyWith(
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: Spacing.xs),
                          _Bar(
                            fraction: counts[type]! / total,
                            color: p.chart[i % p.chart.length],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(Radii.pill);
    return Container(
      height: Spacing.sm,
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(color: AppPalette.of(context).surface2, borderRadius: shape),
      child: FractionallySizedBox(
        widthFactor: fraction,
        heightFactor: 1,
        child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: shape)),
      ),
    );
  }
}
