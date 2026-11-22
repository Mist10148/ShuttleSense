import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/router/app_router.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/data_display.dart';
import '../../shared/widgets/status_pill.dart';
import '../../shared/widgets/surfaces.dart';
import '../results/results_screen.dart';
import '../../core/theme/tokens.dart';

/// Jobs deleted in this session. They are hidden at once, before the refreshed list
/// arrives, so a swiped-away tile is never built again (Dismissible requires that).
final _deletedJobsProvider = StateProvider.autoDispose<Set<String>>((ref) => {});

/// The History search text. The top bar's search writes it too, then opens History.
final historyQueryProvider = StateProvider<String>((ref) => '');

/// Which jobs the list shows.
enum _ModeFilter { all, upload, live }

/// Past jobs on the connected server: search, filter and sort them, open or delete them
/// (privacy).
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  late final TextEditingController _search;
  _ModeFilter _mode = _ModeFilter.all;
  bool _newestFirst = true;
  DateTime? _updated;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(text: ref.read(historyQueryProvider));
    ref.listenManual(jobsListProvider, (_, next) {
      if (next.hasValue && !next.isLoading) setState(() => _updated = DateTime.now());
    }, fireImmediately: true);
    // A search typed in the top bar shows up in this field.
    ref.listenManual(historyQueryProvider, (_, next) {
      if (_search.text != next) _search.text = next;
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Job> _visible(List<Job> all, Set<String> deleted) {
    final query = ref.watch(historyQueryProvider).trim().toLowerCase();
    final list = [
      for (final j in all)
        if (!deleted.contains(j.id) &&
            switch (_mode) {
              _ModeFilter.all => true,
              _ModeFilter.upload => !j.isLive,
              _ModeFilter.live => j.isLive,
            } &&
            (query.isEmpty ||
                j.id.toLowerCase().contains(query) ||
                (ref.watch(videoProvider(j.videoId)).valueOrNull?.filename ?? '')
                    .toLowerCase()
                    .contains(query)))
          j,
    ];
    list.sort(
      (a, b) =>
          _newestFirst ? b.createdAt.compareTo(a.createdAt) : a.createdAt.compareTo(b.createdAt),
    );
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final jobs = ref.watch(jobsListProvider);
    final deleted = ref.watch(_deletedJobsProvider);
    final gutter = Breakpoints.gutter(Breakpoints.of(context));
    final updated = _updated;
    final header = PageHeader(
      title: 'History',
      below: updated == null ? null : 'Updated ${_clock(updated)}',
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
    );
    Widget padded(Widget child) => Padding(
      padding: EdgeInsets.symmetric(horizontal: gutter),
      child: MaxWidth(
        maxWidth: 960,
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: Spacing.xl),
            padded(header),
            Expanded(
              child: jobs.when(
                // Grey rows in the shape of the list while it loads.
                loading: () => ListView(
                  padding: const EdgeInsets.only(top: Spacing.lg),
                  children: [
                    for (var i = 0; i < 5; i++)
                      padded(
                        const Padding(
                          padding: EdgeInsets.only(bottom: Spacing.sm),
                          child: Skeleton(height: 72, radius: Radii.lg),
                        ),
                      ),
                  ],
                ),
                error: (e, _) => MessageView(
                  icon: Icons.wifi_off,
                  message: 'Could not load jobs',
                  detail: '$e',
                  action: FilledButton(
                    onPressed: () => ref.invalidate(jobsListProvider),
                    child: const Text('Retry'),
                  ),
                ),
                data: (all) {
                  if (all.every((j) => deleted.contains(j.id))) {
                    return MessageView(
                      icon: Icons.history,
                      message: 'No analyses on this server yet',
                      detail:
                          'Upload a clip or run a live session. Finished analyses and saved '
                          'live sessions appear here.',
                      action: FilledButton.icon(
                        onPressed: () => context.go(Routes.home),
                        icon: const Icon(Icons.add),
                        label: const Text('Start an analysis'),
                      ),
                    );
                  }
                  final list = _visible(all, deleted);
                  return RefreshIndicator(
                    onRefresh: () => ref.refresh(jobsListProvider.future),
                    child: ListView(
                      padding: const EdgeInsets.only(top: Spacing.lg, bottom: Spacing.xxl),
                      children: [
                        padded(_controls()),
                        const SizedBox(height: Spacing.sm),
                        if (list.isEmpty)
                          padded(
                            const Padding(
                              padding: EdgeInsets.all(Spacing.xl),
                              child: Text('No analyses match.', textAlign: TextAlign.center),
                            ),
                          ),
                        for (final job in list)
                          padded(_JobTile(key: ValueKey(job.id), job: job, all: all)),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls() => Wrap(
    spacing: Spacing.sm,
    runSpacing: Spacing.sm,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      SizedBox(
        width: 280,
        child: TextField(
          controller: _search,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Search by file name',
          ),
          onChanged: (v) => ref.read(historyQueryProvider.notifier).state = v,
        ),
      ),
      SegmentedButton<_ModeFilter>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: _ModeFilter.all, label: Text('All')),
          ButtonSegment(value: _ModeFilter.upload, label: Text('Upload')),
          ButtonSegment(value: _ModeFilter.live, label: Text('Live')),
        ],
        selected: {_mode},
        onSelectionChanged: (s) => setState(() => _mode = s.first),
      ),
      TextButton.icon(
        onPressed: () => setState(() => _newestFirst = !_newestFirst),
        icon: Icon(_newestFirst ? Icons.arrow_downward : Icons.arrow_upward),
        label: Text(_newestFirst ? 'Newest first' : 'Oldest first'),
      ),
    ],
  );
}

/// "14:02".
String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// What the user chose in the delete dialog.
enum _DeleteChoice { results, resultsAndVideo }

class _JobTile extends ConsumerWidget {
  const _JobTile({super.key, required this.job, required this.all});

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
    final when = formatJobDate(job.createdAt);
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
      child: Padding(
        padding: const EdgeInsets.only(bottom: Spacing.sm),
        child: AppCard(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: Spacing.xs),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            // The pastel backs up the icon shape: finished, failed, or still neutral.
            leading: Semantics(
              label: job.status.name,
              child: IconChip(
                icon: switch (job.status) {
                  JobStatus.done => Icons.check_circle_outline,
                  JobStatus.failed => Icons.error_outline,
                  JobStatus.cancelled => Icons.cancel_outlined,
                  _ => Icons.hourglass_top,
                },
                background: switch (job.status) {
                  JobStatus.done => AppPalette.of(context).mint,
                  JobStatus.failed => AppPalette.of(context).pink,
                  _ => AppPalette.of(context).surface2,
                },
              ),
            ),
            title: Text(title, overflow: TextOverflow.ellipsis),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: Spacing.xs),
              child: Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  jobStatusPill(job),
                  Text(
                    '${job.isLive ? 'Live' : 'Upload'} · '
                    '${job.court == 'doubles' ? 'Doubles' : 'Singles'} · $when'
                    '${job.status == JobStatus.running && job.currentStage != null ? ' · ${job.currentStage} ${(job.progress * 100).round()}%' : ''}'
                    ' · ${job.id}',
                  ),
                ],
              ),
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
        ),
      ),
    );
  }
}

/// "2026-11-18 23:01", local time.
String formatJobDate(DateTime at) {
  final t = at.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// A job's status as a pill: Done, Failed, Cancelled, Queued, Processing.
StatusPill jobStatusPill(Job job) => switch (job.status) {
  JobStatus.done => const StatusPill(label: 'Done', tone: PillTone.good),
  JobStatus.failed => const StatusPill(label: 'Failed', tone: PillTone.bad),
  JobStatus.cancelled => const StatusPill(label: 'Cancelled'),
  JobStatus.queued => const StatusPill(label: 'Queued', tone: PillTone.warning),
  JobStatus.running => const StatusPill(label: 'Processing', tone: PillTone.info),
};

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
