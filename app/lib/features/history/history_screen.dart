import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/router/app_router.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import '../results/results_screen.dart';

/// Past jobs on the connected server; open or delete them (privacy).
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = ref.watch(jobsListProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
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
        data: (list) => list.isEmpty
            ? const MessageView(icon: Icons.history, message: 'No analyses on this server yet')
            : RefreshIndicator(
                onRefresh: () => ref.refresh(jobsListProvider.future),
                child: ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) =>
                      MaxWidth(maxWidth: 900, child: _JobTile(job: list[i])),
                ),
              ),
      ),
    );
  }
}

/// What the user chose in the delete dialog.
enum _DeleteChoice { results, resultsAndVideo }

class _JobTile extends ConsumerWidget {
  const _JobTile({required this.job});

  final Job job;

  Future<_DeleteChoice?> _confirm(BuildContext context) =>
      showDialog<_DeleteChoice>(context: context, builder: (context) => const _DeleteDialog());

  Future<void> _delete(BuildContext context, WidgetRef ref, _DeleteChoice choice) async {
    final api = ref.read(apiClientProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (choice == _DeleteChoice.resultsAndVideo) {
        // Deleting the video also deletes every job made from it (docs/API.md).
        await api.deleteVideo(job.videoId);
      } else {
        await api.deleteJob(job.id);
      }
    } on Exception catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('Could not delete: $e')));
    }
    ref.invalidate(jobsListProvider);
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
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.delete_outline),
      ),
      confirmDismiss: (_) async {
        final choice = await _confirm(context);
        if (choice == null || !context.mounted) return false;
        await _delete(context, ref, choice);
        return true;
      },
      child: ListTile(
        leading: Icon(switch (job.status) {
          JobStatus.done => Icons.check_circle_outline,
          JobStatus.failed => Icons.error_outline,
          JobStatus.cancelled => Icons.cancel_outlined,
          _ => Icons.hourglass_top,
        }, semanticLabel: job.status.name),
        title: Text(title, overflow: TextOverflow.ellipsis),
        subtitle: Text('$when · ${job.status.name} · ${job.id}'),
        onTap: () => context.go(hasResults(job) ? Routes.results(job.id) : Routes.job(job.id)),
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
