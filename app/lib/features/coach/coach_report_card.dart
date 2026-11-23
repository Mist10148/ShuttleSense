import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/tokens.dart';
import '../../data/api_client.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/coach.dart';
import '../../data/repositories/analysis_repository.dart';
import '../results/widgets/session_summary.dart';

/// GET /jobs/{id}/coach/report, and POST to write it again (D42).
class CoachReportController extends AutoDisposeFamilyAsyncNotifier<CoachReport, String> {
  @override
  Future<CoachReport> build(String jobId) => ref.read(apiClientProvider).coachReport(jobId);

  Future<void> refresh() async {
    state = const AsyncLoading<CoachReport>().copyWithPrevious(state);
    state = await AsyncValue.guard(
      () => ref.read(apiClientProvider).coachReport(arg, refresh: true),
    );
  }
}

final coachReportProvider =
    AutoDisposeAsyncNotifierProviderFamily<CoachReportController, CoachReport, String>(
      CoachReportController.new,
    );

/// The AI coaching report on the results Coach tab: summary, strengths, weaknesses with
/// tap-to-seek moments, drills and goals for the next session.
class CoachReportCard extends ConsumerWidget {
  const CoachReportCard({super.key, required this.jobId, required this.fps, this.onSeek});

  final String jobId;
  final double fps;

  /// Null when there is no video to seek.
  final ValueChanged<Moment>? onSeek;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final report = ref.watch(coachReportProvider(jobId));
    final busy = report.isLoading;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text('Coaching report', style: theme.textTheme.titleMedium)),
                IconButton(
                  tooltip: 'Write the report again',
                  onPressed: busy
                      ? null
                      : () => ref.read(coachReportProvider(jobId).notifier).refresh(),
                  icon: busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            switch (report) {
              AsyncValue(:final CoachReport value) => _ReportBody(
                report: value,
                fps: fps,
                onSeek: onSeek,
              ),
              AsyncValue(:final Object error) => Text(
                error is ApiException ? error.message : 'Could not load the report: $error',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              _ => const Padding(
                padding: EdgeInsets.all(Spacing.md),
                child: Center(child: Text('Writing your coaching report…')),
              ),
            },
          ],
        ),
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.report, required this.fps, required this.onSeek});

  final CoachReport report;
  final double fps;
  final ValueChanged<Moment>? onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = theme.textTheme.titleSmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(report.summary),
        if (report.fromRules)
          Text(
            'Built from the session notes (no AI provider answered).',
            style: theme.textTheme.bodySmall,
          ),
        if (report.strengths.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          Text('Strengths', style: heading),
          for (final s in report.strengths) _Bullet(text: s, icon: Icons.thumb_up_outlined),
        ],
        if (report.weaknesses.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          Text('To work on', style: heading),
          for (final w in report.weaknesses)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(w.title, style: theme.textTheme.bodyLarge),
                  Text(w.evidence, style: theme.textTheme.bodySmall),
                  if (w.drill != null) Text('Drill: ${w.drill}', style: theme.textTheme.bodySmall),
                  if (onSeek case final seek? when w.moments.isNotEmpty) ...[
                    const SizedBox(height: Spacing.xs),
                    MomentChips(moments: w.momentsAt(fps), onSeek: seek),
                  ],
                ],
              ),
            ),
        ],
        if (report.drills.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          Text('Drills', style: heading),
          for (final d in report.drills)
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              title: Text(d.name),
              subtitle: Text(d.purpose),
              children: [
                Align(alignment: Alignment.centerLeft, child: Text(d.how)),
                const SizedBox(height: Spacing.sm),
              ],
            ),
        ],
        if (report.nextSessionGoals.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          Text('Next session', style: heading),
          for (final g in report.nextSessionGoals) _Bullet(text: g, icon: Icons.flag_outlined),
        ],
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text, required this.icon});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: Spacing.sm),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
