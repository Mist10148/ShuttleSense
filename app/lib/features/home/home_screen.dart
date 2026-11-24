import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/data_display.dart';
import '../../shared/widgets/instruments.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';
import '../../shared/widgets/tactile.dart';
import '../history/history_screen.dart';
import '../mode/mode_screen.dart';
import '../../ui/depth.dart';
import '../results/results_screen.dart' show hasResults;
import '../results/widgets/stroke_timeline.dart' show formatClock;

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
    final side = [
      if (jobs.isEmpty) const _FirstRun() else _RecentAnalyses(jobs: jobs.take(_kRecent).toList()),
      if (jobs.isEmpty || latestDone == null) const _CameraTip(),
    ];
    return PageScaffold(
      title: 'Home',
      showBack: false,
      maxWidth: 1640,
      children: [
        Semantics(header: true, child: const EngravedLabel('Start an analysis')),
        const SizedBox(height: Spacing.md),
        const ModeChoices(),
        const SizedBox(height: Spacing.xl),
        LayoutBuilder(
          builder: (context, box) {
            final latest = latestDone == null ? null : _LatestAnalysis(job: latestDone);
            if (box.maxWidth < 1000 || latest == null) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (latest != null) ...[latest, const SizedBox(height: Spacing.xl)],
                  for (final w in side) ...[w, const SizedBox(height: Spacing.xl)],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: latest),
                const SizedBox(width: Spacing.xl),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, w) in side.indexed) ...[
                        if (i > 0) const SizedBox(height: Spacing.xl),
                        w,
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// No analyses on this server yet: say what Home will show and open the mode picker.
class _FirstRun extends StatelessWidget {
  const _FirstRun();

  @override
  Widget build(BuildContext context) => AppCard(
    child: MessageView(
      icon: Icons.sports_tennis,
      message: 'No analyses yet',
      detail: 'Your latest analyses and their stroke mix show up here.',
      action: FilledButton.icon(
        onPressed: () => context.go(Routes.mode),
        icon: const Icon(Icons.insights_outlined),
        label: const Text('Choose an analysis mode'),
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
      icon: Icons.videocam_outlined,
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
    icon: Icons.history,
    subtitle: 'Newest first',
    onExpand: () => context.go(Routes.history),
    padding: const EdgeInsets.fromLTRB(Spacing.xl, Spacing.xl, Spacing.md, Spacing.md),
    // A recessed box behind the rows, so the list sits in the card rather than on it.
    child: InsetBox(
      radius: 16,
      padding: const EdgeInsets.all(Spacing.sm),
      child: Column(
        children: [
          for (final (i, job) in jobs.indexed) ...[
            if (i > 0) const SizedBox(height: Spacing.sm),
            _RecentRow(job: job),
          ],
        ],
      ),
    ),
  );
}

class _RecentRow extends ConsumerWidget {
  const _RecentRow({required this.job});

  final Job job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AppPalette.of(context);
    final name = ref.watch(videoProvider(job.videoId)).valueOrNull?.filename;
    final running = !job.status.isFinished && job.status != JobStatus.needsSelection;
    final title = name ?? (job.isLive ? 'Live session' : 'Analysis');
    // The same card History uses for its rows, so the hover is identical: the whole row
    // lifts and gets a blue outline under the pointer.
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.xs, vertical: 2),
      semanticLabel: title,
      onTap: () => context.go(
        job.mode == 'practice'
            ? Routes.practice(job.id)
            : hasResults(job)
            ? Routes.results(job.id)
            : Routes.job(job.id),
      ),
      child: ListRow(
        // The same icon and pastel as the job's mode card.
        leading: IconChip(
          icon: job.mode == 'practice'
              ? Icons.sports_tennis
              : job.isLive
              ? Icons.videocam_outlined
              : Icons.movie_outlined,
          background: job.mode == 'practice'
              ? p.peach
              : job.isLive
              ? p.sky
              : p.lavender,
        ),
        title: title,
        subtitle:
            '${job.mode == 'practice'
                ? 'AI Coach'
                : job.isLive
                ? 'Live'
                : 'Upload'} · ${formatJobDate(job.createdAt)}',
        trailing: running
            ? SizedBox(
                width: 88,
                child: GradientProgress(value: job.progress, label: 'Processing'),
              )
            : jobStatusPill(job),
      ),
    );
  }
}

/// The latest finished analysis as an instrument panel: its peak speed on a dial, its
/// headline numbers in wells, and its stroke mix as a bank of faders.
class _LatestAnalysis extends ConsumerWidget {
  const _LatestAnalysis({required this.job});

  final Job job;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final record = ref.watch(recordProvider(job.id)).valueOrNull;
    final summary = record?.summary;
    final counts = summary?.strokeCounts;
    final name = ref.watch(videoProvider(job.videoId)).valueOrNull?.filename;
    final types = [
      for (final type in kStrokeLabels.keys)
        if ((counts?[type] ?? 0) > 0) type,
    ];
    final total = types.fold<int>(0, (sum, t) => sum + counts![t]!);
    final seconds = record != null && record.fps > 0 && record.numFrames > 0
        ? record.numFrames / record.fps
        : null;
    final stats = [
      if (summary != null) ('Strokes', '${summary.totalHits}'),
      if (record != null && record.rallies.isNotEmpty) ('Rallies', '${record.rallies.length}'),
      if (seconds != null) ('Clip length', formatClock(seconds)),
    ];

    final Widget mix = counts == null
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
        : InsetBox(
            radius: Radii.lg,
            padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.lg, Spacing.md, Spacing.md),
            child: Wrap(
              alignment: WrapAlignment.spaceAround,
              spacing: Spacing.lg,
              runSpacing: Spacing.lg,
              children: [
                for (final (i, type) in types.indexed)
                  Fader(
                    height: MediaQuery.sizeOf(context).height < 900 ? 100 : 140,
                    fraction: counts[type]! / total,
                    color: p.chart[i % p.chart.length],
                    label: kStrokeLabels[type]!,
                    detail: '${counts[type]} · ${(counts[type]! * 100 / total).round()}%',
                    semanticLabel: '${kStrokeLabels[type]}: ${counts[type]} of $total strokes',
                  ),
              ],
            ),
          );

    return AppCard(
      title: 'Latest analysis',
      icon: Icons.insights_outlined,
      subtitle: name,
      semanticLabel: 'Latest analysis${name == null ? '' : ': $name'}',
      onTap: () => context.go(Routes.results(job.id)),
      onExpand: () => context.go(Routes.results(job.id)),
      child: LayoutBuilder(
        builder: (context, box) {
          final dial = summary?.peakSpeedKmh == null
              ? null
              : SpeedDial(
                  value: summary!.peakSpeedKmh!,
                  label: 'Peak speed',
                  size: MediaQuery.sizeOf(context).height < 900 ? 170 : 200,
                );
          final numbers = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (stats.isNotEmpty) ...[
                Row(
                  children: [
                    for (final (i, (label, value)) in stats.indexed) ...[
                      if (i > 0) const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: KpiTile(label: label, value: value),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Spacing.lg),
              ],
              const EngravedLabel('Stroke mix'),
              const SizedBox(height: Spacing.sm),
              mix,
            ],
          );
          if (dial == null) return numbers;
          if (box.maxWidth < 600) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: dial),
                const SizedBox(height: Spacing.xl),
                numbers,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              dial,
              const SizedBox(width: Spacing.xl),
              Expanded(child: numbers),
            ],
          );
        },
      ),
    );
  }
}
