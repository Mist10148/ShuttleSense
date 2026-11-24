import 'package:flutter/material.dart';

import '../../../shared/widgets/smooth_scroll.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/shuttle_speed.dart';
import '../../../shared/widgets/tactile.dart';
import '../../../data/models/court_view.dart';

/// Seeking lands this long before the hit so the swing is visible.
const kSeekLead = Duration(milliseconds: 500);

/// Video position to seek to for [hit]: [kSeekLead] before it, never negative.
Duration seekTarget(Hit hit) {
  final target = hit.position - kSeekLead;
  return target.isNegative ? Duration.zero : target;
}

/// Height of one timeline row, used to auto-scroll to the current hit.
const double kTimelineRowHeight = 72;

/// Which hits the timeline lists: one side (null: both) and one stroke class (null: all).
typedef TimelineFilterValue = ({String? player, String? stroke});

/// The timeline's filter, shared with [TimelineFilters] when those sit elsewhere (beside the
/// section tabs on the results screen).
class TimelineFilter extends ValueNotifier<TimelineFilterValue> {
  TimelineFilter() : super((player: null, stroke: null));
}

/// Both / Near / Far as a sliding tray, and the stroke menu as a small key.
class TimelineFilters extends StatelessWidget {
  const TimelineFilters({super.key, required this.filter, required this.hits});

  final TimelineFilter filter;
  final List<Hit> hits;

  @override
  Widget build(BuildContext context) {
    final strokes = {for (final h in hits) ?h.stroke};
    return ValueListenableBuilder<TimelineFilterValue>(
      valueListenable: filter,
      builder: (context, f, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The same size as the section tabs beside it.
          DepthSegmented<String?>(
            segments: [
              const ButtonSegment(value: null, label: Text('Both')),
              ButtonSegment(value: 'near', label: Text(context.sideLabel('near'))),
              ButtonSegment(value: 'far', label: Text(context.sideLabel('far'))),
            ],
            selected: {f.player},
            onSelectionChanged: (v) => filter.value = (player: v.first, stroke: f.stroke),
          ),
          const SizedBox(width: Spacing.sm),
          PopupMenuButton<String?>(
            tooltip: 'Filter by stroke',
            initialValue: f.stroke,
            onSelected: (v) => filter.value = (player: f.player, stroke: v == '' ? null : v),
            itemBuilder: (_) => [
              const PopupMenuItem(value: '', child: Text('All strokes')),
              for (final s in strokes) PopupMenuItem(value: s, child: Text(kStrokeLabels[s] ?? s)),
            ],
            child: IgnorePointer(
              child: OutlinedButton(
                // As tall as the trays beside it (44 dp).
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  fixedSize: const Size.fromHeight(44),
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.md + 2),
                ),
                onPressed: () {},
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(f.stroke == null ? 'All strokes' : kStrokeLabels[f.stroke] ?? f.stroke!),
                    const SizedBox(width: 4),
                    const Icon(Icons.expand_more_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Column widths shared by the header and the rows.
const double _kTimeCol = 64, _kPlayerCol = 92, _kSpeedCol = 120;

/// C3 / FR-C3: one row per hit; tapping a row seeks the video, long-press shows details.
class StrokeTimeline extends StatefulWidget {
  const StrokeTimeline({
    super.key,
    required this.hits,
    this.currentHitId,
    required this.onSeek,
    this.filter,
  });

  final List<Hit> hits;
  final int? currentHitId;

  /// Given when the filters are shown elsewhere ([TimelineFilters]); otherwise the timeline
  /// keeps its own and shows them above the rows.
  final TimelineFilter? filter;

  /// Called with the tapped hit; a video seeks to [seekTarget], other views go to the hit.
  final ValueChanged<Hit> onSeek;

  @override
  State<StrokeTimeline> createState() => _StrokeTimelineState();
}

class _StrokeTimelineState extends State<StrokeTimeline> {
  final _scroll = SmoothScrollController();
  TimelineFilter? _own;
  TimelineFilter get _filter => widget.filter ?? (_own ??= TimelineFilter());

  List<Hit> get _visible {
    final f = _filter.value;
    return [
      for (final h in widget.hits)
        if ((f.player == null || h.player == f.player) &&
            (f.stroke == null || h.stroke == f.stroke))
          h,
    ];
  }

  @override
  void didUpdateWidget(StrokeTimeline old) {
    super.didUpdateWidget(old);
    if (old.currentHitId != widget.currentHitId) _scrollToCurrent();
  }

  void _scrollToCurrent() {
    final index = _visible.indexWhere((h) => h.id == widget.currentHitId);
    if (index < 0 || !_scroll.hasClients) return;
    final target = (index * kTimelineRowHeight).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hits.isEmpty) {
      return const MessageView(
        icon: Icons.timeline,
        message: 'No hits detected yet',
        detail: 'Hits and strokes appear here once those pipeline stages are in place.',
      );
    }
    return ValueListenableBuilder<TimelineFilterValue>(
      valueListenable: _filter,
      builder: (context, _, _) {
        final hits = _visible;
        final p = AppPalette.of(context);
        final label = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: p.text3,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.9,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.filter == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.md, Spacing.lg, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: TimelineFilters(filter: _filter, hits: widget.hits),
                  ),
                ),
              ),
            // Column names over the rows.
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.sm + Spacing.md + 3,
                  Spacing.md,
                  Spacing.sm + 48,
                  Spacing.xs,
                ),
                child: LayoutBuilder(
                  builder: (context, box) => Row(
                    children: [
                      SizedBox(
                        width: _kTimeCol,
                        child: _ColumnName('TIME', style: label),
                      ),
                      SizedBox(
                        width: _kPlayerCol,
                        child: _ColumnName('PLAYER', style: label),
                      ),
                      Expanded(child: _ColumnName('STROKE', style: label)),
                      if (box.maxWidth + 48 >= 620)
                        SizedBox(
                          width: _kSpeedCol,
                          child: _ColumnName('SPEED', style: label),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: hits.isEmpty
                  ? const MessageView(
                      icon: Icons.filter_alt_off,
                      message: 'No hits match the filter',
                    )
                  // The rows' chevrons are flat icons, not the theme's raised keys.
                  : Theme(
                      data: Theme.of(
                        context,
                      ).copyWith(iconButtonTheme: const IconButtonThemeData()),
                      child: ListView.builder(
                        controller: _scroll,
                        itemExtent: kTimelineRowHeight,
                        itemCount: hits.length,
                        itemBuilder: (context, i) => _HitRow(
                          hit: hits[i],
                          selected: hits[i].id == widget.currentHitId,
                          onSeek: widget.onSeek,
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

String formatClock(double seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).toStringAsFixed(1).padLeft(4, '0');
  return '$m:$s';
}

class _HitRow extends StatelessWidget {
  const _HitRow({required this.hit, required this.selected, required this.onSeek});

  final Hit hit;
  final bool selected;
  final ValueChanged<Hit> onSeek;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final p = AppPalette.of(context);
    final a = AnalysisColors.of(context);
    final t = TactileTokens.of(context);
    final text = Theme.of(context).textTheme;
    final stroke = kStrokeLabels[hit.stroke] ?? 'Unclassified';
    final player = context.sideLabel(hit.who);
    final details = [
      if (hit.confidence != null) '${(hit.confidence! * 100).round()}%',
      if (hit.speedKmh != null) '~${hit.speedKmh!.round()} km/h (est.)',
      ?hit.tip,
    ].join(' · ');
    final speed = hit.speedKmh;
    final speedColor = shuttleSpeedColor(speed);
    return Semantics(
      button: true,
      label: '$player player, $stroke at ${formatClock(hit.timeS)}',
      hint: 'Double tap to jump to this hit. Long press for details.',
      excludeSemantics: true,
      // The row's own actions are excluded with its semantics, so give them back here.
      onTap: () => onSeek(hit),
      onLongPress: () => showHitDetails(context, hit),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 3),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSeek(hit),
            onLongPress: () => showHitDetails(context, hit),
            child: Ink(
              decoration: BoxDecoration(
                color: selected ? t.primary.withValues(alpha: 0.10) : null,
                borderRadius: BorderRadius.circular(10),
              ),
              child: LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 620;
                  final c = colors.forPlayer(hit.who);
                  return Row(
                    children: [
                      // The current stroke's row has an accent edge.
                      Container(
                        width: 3,
                        decoration: BoxDecoration(
                          color: selected ? t.primary : Colors.transparent,
                          borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
                      SizedBox(
                        width: _kTimeCol,
                        child: Text(
                          formatClock(hit.timeS),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: kFigureStyle.copyWith(
                            fontSize: 15,
                            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                            color: selected ? p.ink : p.text2,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: _kPlayerCol,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: c.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                                ),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    player,
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Color.lerp(c, p.ink, 0.2),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hit.uncertain ? '$stroke ?' : stroke,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.titleSmall?.copyWith(
                                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                            if (details.isNotEmpty)
                              Text(
                                details,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: p.text3, fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                      if (wide)
                        SizedBox(
                          width: _kSpeedCol,
                          child: speed == null || speedColor == null
                              ? const SizedBox.shrink()
                              : ExcludeSemantics(
                                  child: Container(
                                    height: 6,
                                    margin: const EdgeInsets.only(right: Spacing.md),
                                    alignment: Alignment.centerLeft,
                                    decoration: BoxDecoration(
                                      color: a.track,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: FractionallySizedBox(
                                      widthFactor: (speed / 300).clamp(0.04, 1.0),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: speedColor,
                                          borderRadius: BorderRadius.circular(3),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      IconButton(
                        tooltip: 'Details',
                        color: p.text3,
                        iconSize: 20,
                        icon: const Icon(Icons.chevron_right_rounded),
                        onPressed: () => showHitDetails(context, hit),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// F8 / T5.9: stroke probabilities and every form rule with pass/fail.
Future<void> showHitDetails(BuildContext context, Hit hit) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => _HitDetails(hit: hit),
);

class _HitDetails extends StatelessWidget {
  const _HitDetails({required this.hit});

  final Hit hit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final probs = hit.classProbs.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(Spacing.xl, 0, Spacing.xl, Spacing.xl),
        children: [
          Text(
            '${kStrokeLabels[hit.stroke] ?? 'Unclassified'} · '
            '${context.sideLabel(hit.who)} player · ${formatClock(hit.timeS)}',
            style: theme.textTheme.titleMedium,
          ),
          if (hit.uncertain)
            Text(
              'Low confidence: the model is unsure about this stroke.',
              style: theme.textTheme.bodySmall,
            ),
          if (probs.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            for (final p in probs.take(3))
              Row(
                children: [
                  SizedBox(width: 80, child: Text(kStrokeLabels[p.key] ?? p.key)),
                  Expanded(child: LinearProgressIndicator(value: p.value)),
                  SizedBox(
                    width: 48,
                    child: Text('${(p.value * 100).round()}%', textAlign: TextAlign.end),
                  ),
                ],
              ),
          ],
          const SizedBox(height: Spacing.lg),
          Text('Form feedback', style: theme.textTheme.titleSmall),
          if (hit.feedback.isEmpty)
            Text('No rules could be checked for this hit.', style: theme.textTheme.bodySmall),
          for (final fb in hit.feedback)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                fb.passed ? Icons.check_circle : Icons.cancel,
                color: fb.passed ? scheme.primary : scheme.error,
                semanticLabel: fb.passed ? 'passed' : 'failed',
              ),
              title: Text(fb.label),
              subtitle: fb.tip == null ? null : Text(fb.tip!),
            ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Heuristic guidance, not professional coaching.',
            style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

/// A column name over the timeline: one line, cut short rather than wrapped.
class _ColumnName extends StatelessWidget {
  const _ColumnName(this.name, {this.style});

  final String name;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) =>
      Text(name, style: style, maxLines: 1, softWrap: false, overflow: TextOverflow.clip);
}
