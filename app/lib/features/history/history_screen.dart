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

class _JobTile extends ConsumerWidget {
  const _JobTile({required this.job});

  final Job job;

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete analysis?'),
        content: const Text('The results are removed from the server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(apiClientProvider).deleteJob(job.id);
    ref.invalidate(jobsListProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final created = job.createdAt.toLocal();
    final when =
        '${created.year}-${created.month.toString().padLeft(2, '0')}-'
        '${created.day.toString().padLeft(2, '0')} '
        '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    return ListTile(
      leading: Icon(switch (job.status) {
        JobStatus.done => Icons.check_circle_outline,
        JobStatus.failed => Icons.error_outline,
        JobStatus.cancelled => Icons.cancel_outlined,
        _ => Icons.hourglass_top,
      }),
      title: Text('Analysis ${job.id}'),
      subtitle: Text('$when · ${job.status.name}'),
      onTap: () => context.go(hasResults(job) ? Routes.results(job.id) : Routes.job(job.id)),
      trailing: IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _delete(context, ref),
      ),
    );
  }
}
