import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import 'tactile.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/job.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../features/history/history_screen.dart';
import '../../features/results/results_screen.dart';
import 'status_pill.dart';
import 'surfaces.dart';
import '../../ui/depth.dart';

/// How many analyses the notifications menu lists.
const _kRecentJobs = 6;

/// On a wide window the top bar floats over the top-right corner of the page, so the page's
/// title row shares its line instead of starting under an empty band. [width] is how much of
/// that line, from the right edge, the bar takes; a page header keeps clear of it.
class TopBarReserve extends InheritedNotifier<ValueNotifier<Size>> {
  const TopBarReserve({
    super.key,
    required ValueNotifier<Size> size,
    required this.shared,
    required super.child,
  }) : super(notifier: size);

  /// Whether the page on screen puts its title on the bar's line (Results only); other
  /// pages start under the bar and their headers keep their full width.
  final bool shared;

  /// The floating bar's size while the page shares its line, else null.
  static Size? maybeOf(BuildContext context) {
    final reserve = context.dependOnInheritedWidgetOfExactType<TopBarReserve>();
    return reserve != null && reserve.shared ? reserve.notifier?.value : null;
  }

  @override
  bool updateShouldNotify(TopBarReserve oldWidget) =>
      oldWidget.shared != shared || super.updateShouldNotify(oldWidget);
}

/// The bar above every page in the shell: search, analysis notifications and the server
/// status. On a phone the search collapses to an icon and the brand shows on the left.
class TopBar extends StatelessWidget {
  const TopBar({super.key, required this.compact, this.size});

  final bool compact;

  /// Kept up to date with the bar's laid-out size (the floating bar on a wide window).
  final ValueNotifier<Size>? size;

  @override
  Widget build(BuildContext context) {
    final bar = _bar(context);
    final notify = size;
    if (notify == null) return bar;
    // Measured after each frame it is built in (its status label changes its width).
    return Builder(
      builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _report(context, notify));
        return bar;
      },
    );
  }

  static void _report(BuildContext context, ValueNotifier<Size> notify) {
    if (!context.mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final s = box.size;
    if (s != notify.value) notify.value = s;
  }

  Widget _bar(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? Spacing.lg : Spacing.md,
        compact ? Spacing.sm : Spacing.lg,
        compact ? Spacing.sm : Spacing.xxl,
        compact ? Spacing.sm : Spacing.xs,
      ),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (compact) ...[
            IconChip(
              icon: Icons.sports_tennis,
              size: 32,
              background: AppPalette.of(context).lavender,
            ),
            const SizedBox(width: Spacing.sm),
            Expanded(child: Text('ShuttleSense', style: text.titleMedium)),
            IconButton(
              tooltip: 'Search analyses',
              onPressed: () => context.go(Routes.history),
              icon: const Icon(Icons.search),
            ),
          ] else ...[
            const SizedBox(width: 300, child: _SearchField()),
            const SizedBox(width: Spacing.lg),
          ],
          // Three separate controls, one height, even gaps: the search slot, the bell key and
          // the server status plate.
          const _NotificationsButton(),
          SizedBox(width: compact ? Spacing.xs : Spacing.md),
          _ServerStatus(compact: compact),
        ],
      ),
    );
  }
}

/// Searches analyses by file name: the text goes to History's search and History opens.
class _SearchField extends ConsumerWidget {
  const _SearchField();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A slot sunk into the chassis.
    return InsetBox(
      radius: Radii.pill,
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: 44,
        child: TextField(
          textInputAction: TextInputAction.search,
          textAlignVertical: TextAlignVertical.center,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search, size: 20),
            // The icon box matches the slot height, so the text centres in it.
            prefixIconConstraints: BoxConstraints(minWidth: 44, minHeight: 44),
            hintText: 'Search analyses',
            isDense: true,
            contentPadding: EdgeInsets.fromLTRB(0, 12, Spacing.lg, 12),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
          onSubmitted: (v) {
            ref.read(historyQueryProvider.notifier).state = v.trim();
            context.go(Routes.history);
          },
        ),
      ),
    );
  }
}

/// A bell with the number of analyses still running; its menu lists the latest ones.
class _NotificationsButton extends ConsumerWidget {
  const _NotificationsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobs = [...?ref.watch(jobsListProvider).valueOrNull]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final running = jobs.where((j) => !j.status.isFinished).length;
    return MenuAnchor(
      // Fetch the list again each time the menu opens, so it is never stale.
      onOpen: () => ref.invalidate(jobsListProvider),
      menuChildren: [
        if (jobs.isEmpty) const MenuItemButton(onPressed: null, child: Text('No analyses yet')),
        for (final job in jobs.take(_kRecentJobs))
          MenuItemButton(
            leadingIcon: Icon(_icon(job.status)),
            onPressed: () =>
                context.go(hasResults(job) ? Routes.results(job.id) : Routes.job(job.id)),
            child: Text(_describe(job)),
          ),
      ],
      builder: (context, menu, _) => IconButton(
        style: tactileButtonStyle(TactileButtonKind.secondary, radius: 22).copyWith(
          minimumSize: const WidgetStatePropertyAll(Size.square(44)),
          fixedSize: const WidgetStatePropertyAll(Size.square(44)),
        ),
        tooltip: running == 0 ? 'Notifications' : 'Notifications: $running running',
        onPressed: () => menu.isOpen ? menu.close() : menu.open(),
        icon: Badge(
          isLabelVisible: running > 0,
          label: Text('$running'),
          child: const Icon(Icons.notifications_none),
        ),
      ),
    );
  }

  static IconData _icon(JobStatus status) => switch (status) {
    JobStatus.done => Icons.check_circle_outline,
    JobStatus.failed => Icons.error_outline,
    JobStatus.cancelled => Icons.cancel_outlined,
    JobStatus.queued || JobStatus.running => Icons.hourglass_top,
  };

  static String _describe(Job job) {
    final kind = job.isLive ? 'Live session' : 'Analysis';
    return switch (job.status) {
      JobStatus.done => '$kind finished',
      JobStatus.failed => '$kind failed',
      JobStatus.cancelled => '$kind cancelled',
      JobStatus.queued => '$kind queued',
      JobStatus.running => '$kind running · ${(job.progress * 100).round()}%',
    };
  }
}

/// Online, offline or checking, from GET /health. Opens Settings, where the connection is.
class _ServerStatus extends ConsumerWidget {
  const _ServerStatus({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (label, tone) = ref
        .watch(healthProvider)
        .when(
          loading: () => ('Checking…', PillTone.neutral),
          error: (_, _) => ('Offline', PillTone.bad),
          data: (_) => ('Online', PillTone.good),
        );
    return Tooltip(
      message: 'Server: $label',
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.pill),
        onTap: () => context.go(Routes.settings),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTouchTarget, minWidth: kMinTouchTarget),
          child: Center(
            widthFactor: 1,
            child: compact
                ? _Dot(tone: tone, label: 'Server $label')
                : _StatusPlate(label: label, tone: tone),
          ),
        ),
      ),
    );
  }
}

/// Just the coloured status dot, for the phone top bar.
class _Dot extends StatelessWidget {
  const _Dot({required this.tone, required this.label});

  final PillTone tone;
  final String label;

  @override
  Widget build(BuildContext context) {
    final status = StatusColors.of(context);
    final colour = switch (tone) {
      PillTone.good => status.inCall,
      PillTone.bad => status.outCall,
      _ => AppPalette.of(context).text3,
    };
    return Semantics(
      label: label,
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      ),
    );
  }
}

/// The server status on the wide top bar: a raised plate the height of the search slot,
/// with a status light and the word.
class _StatusPlate extends StatelessWidget {
  const _StatusPlate({required this.label, required this.tone});

  final String label;
  final PillTone tone;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final status = StatusColors.of(context);
    final light = switch (tone) {
      PillTone.good => status.inCall,
      PillTone.bad => status.outCall,
      _ => p.text3,
    };
    return Raised(
      radius: Radii.pill,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Led(color: light, size: 8, glow: tone != PillTone.neutral),
            const SizedBox(width: Spacing.sm),
            Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: p.ink)),
          ],
        ),
      ),
    );
  }
}
