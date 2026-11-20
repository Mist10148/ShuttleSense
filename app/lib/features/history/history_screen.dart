import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/router/app_router.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import '../results/results_screen.dart';
import '../../core/theme/tokens.dart';

/// Jobs deleted in this session. They are hidden at once, before the refreshed list
/// arrives, so a swiped-away tile is never built again (Dismissible requires that).
final _deletedJobsProvider = StateProvider.autoDispose<Set<String>>((ref) => {});

/// Past jobs on the connected server; open or delete them (privacy).
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsListProvider);
    final deleted = ref.watch(_deletedJobsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Ask the coach',
            onPressed: () => context.push(Routes.coach),
            icon: const Icon(Icons.forum_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => ref.invalidate(jobsListProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: jobs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => MessageView(
          icon: Icons.wifi_off,
          message: 'Could not load jobs',
          detail: '$e',
          action: FilledButton(
            onPressed: () => ref.invalidate(jobsListProvider),
            child: const Text('Retry'),
          ),
        ),
        data: (all) => switch ([
          for (final j in all)
            if (!deleted.contains(j.id)) j,
        ]) {
          final list =>
            list.isEmpty
                ? const MessageView(icon: Icons.history, message: 'No analyses on this server yet')
                : RefreshIndicator(
                    onRefresh: () => ref.refresh(jobsListProvider.future),
                    child: ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, i) => MaxWidth(
                        maxWidth: 900,
                        child: _JobTile(job: list[i], all: all),
                      ),
                    ),
                  ),
        },
      ),
    );
  }
}

/// What the user chose in the delete dialog.
enum _DeleteChoice { results, resultsAndVideo }

class _JobTile extends ConsumerWidget {
  const _JobTile({required this.job, required this.all});

  final Job job;

  /// Every listed job, to hide the ones a video delete takes with it.
  final List<Job> all;

  Future<_DeleteChoice?> _confirm(BuildContext context) =>
      showDialog<_DeleteChoice>(context: context, builder: (context) => const _DeleteDialog());

  /// True when the server deleted it. Everything from [ref] is read before the first await:
  /// a swiped tile may be gone by the time the request returns.
  Future<bool> _delete(BuildContext context, WidgetRef ref, _DeleteChoice choice) async {
    final api = ref.read(apiClientProvider);
    final deleted = ref.read(_deletedJobsProvider.notifier);
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (choice == _DeleteChoice.resultsAndVideo) {
        // Deleting the video also deletes every job made from it (docs/API.md).
        await api.deleteVideo(job.videoId);
        deleted.state = {
          ...deleted.state,
          for (final j in all)
            if (j.videoId == job.videoId) j.id,
        };
      } else {
        await api.deleteJob(job.id);
        deleted.state = {...deleted.state, job.id};
      }
      return true;
    } on Exception catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      return false;
    } finally {
      container.invalidate(jobsListProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final video = ref.watch(videoProvider(job.videoId)).valueOrNull;
    final created = job.createdAt.toLocal();
    final when =
        '${created.year}-${created.month.toString().padLeft(2, '0')}-'
        '${created.day.toString().padLeft(2, '0')} '
        '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    final title = video?.filename ?? 'Analysis ${job.id}';
    return Dismissible(
      key: ValueKey(job.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
        child: const Icon(Icons.delete_outline),
      ),
      confirmDismiss: (_) async {
        final choice = await _confirm(context);
        if (choice == null || !context.mounted) return false;
        return _delete(context, ref, choice);
      },
      child: ListTile(
        leading: Icon(
          switch (job.status) {
            JobStatus.done => Icons.check_circle_outline,
            JobStatus.failed => Icons.error_outline,
            JobStatus.cancelled => Icons.cancel_outlined,
            _ => Icons.hourglass_top,
          },
          semanticLabel: job.status.name,
          // Colour backs up the icon shape: finished, failed, or still neutral.
          color: switch (job.status) {
            JobStatus.done => Theme.of(context).colorScheme.primary,
            JobStatus.failed => Theme.of(context).colorScheme.error,
            _ => Theme.of(context).colorScheme.onSurfaceVariant,
          },
        ),
        title: Text(title, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${job.isLive ? 'Live · ' : ''}$when · ${job.status.name}'
          '${job.status == JobStatus.running && job.currentStage != null ? ' · ${job.currentStage} ${(job.progress * 100).round()}%' : ''} · ${job.id}',
        ),
        onTap: () {
          if (job.status == JobStatus.done && !hasResults(job)) {
            // Finished, but its record is gone (e.g. the server's storage was wiped).
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('This job has no results on the server any more.')),
            );
            return;
          }
          context.go(hasResults(job) ? Routes.results(job.id) : Routes.job(job.id));
        },
        trailing: IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline),
          onPressed: () async {
            final choice = await _confirm(context);
            if (choice != null && context.mounted) await _delete(context, ref, choice);
          },
        ),
      ),
    );
  }
}

class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog();

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  bool _withVideo = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Delete analysis?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('The results are removed from the server.'),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _withVideo,
          onChanged: (v) => setState(() => _withVideo = v ?? false),
          title: const Text('Also delete the uploaded video'),
          subtitle: const Text('and every analysis of it'),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _withVideo ? _DeleteChoice.resultsAndVideo : _DeleteChoice.results,
        ),
        child: const Text('Delete'),
      ),
    ],
  );
}
