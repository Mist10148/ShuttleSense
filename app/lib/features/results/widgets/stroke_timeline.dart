import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../shared/widgets/shuttle_speed.dart';

/// Seeking lands this long before the hit so the swing is visible.
const kSeekLead = Duration(milliseconds: 500);

/// Video position to seek to for [hit]: [kSeekLead] before it, never negative.
Duration seekTarget(Hit hit) {
  final target = hit.position - kSeekLead;
  return target.isNegative ? Duration.zero : target;
}

/// Height of one timeline row, used to auto-scroll to the current hit.
const double kTimelineRowHeight = 72;

/// C3 / FR-C3: one row per hit; tapping a row seeks the video, long-press shows details.
class StrokeTimeline extends StatefulWidget {
  const StrokeTimeline({super.key, required this.hits, this.currentHitId, required this.onSeek});

  final List<Hit> hits;
  final int? currentHitId;

  /// Called with the tapped hit; a video seeks to [seekTarget], other views go to the hit.
  final ValueChanged<Hit> onSeek;

  @override
  State<StrokeTimeline> createState() => _StrokeTimelineState();
}

class _StrokeTimelineState extends State<StrokeTimeline> {
  final _scroll = ScrollController();
  String? _player; // near / far / null = both
  String? _stroke; // a stroke class / null = all

  List<Hit> get _visible => [
    for (final h in widget.hits)
      if ((_player == null || h.player == _player) && (_stroke == null || h.stroke == _stroke)) h,
  ];

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
    final strokes = {for (final h in widget.hits) ?h.stroke};
    final hits = _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.md, Spacing.lg, Spacing.sm),
          child: Row(
            children: [
              for (final (value, label) in [(null, 'Both'), ('near', 'Near'), ('far', 'Far')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _player == value,
                    onSelected: (_) => setState(() => _player = value),
                  ),
                ),
              const SizedBox(width: Spacing.sm),
              PopupMenuButton<String?>(
                tooltip: 'Filter by stroke',
                initialValue: _stroke,
                onSelected: (v) => setState(() => _stroke = v == '' ? null : v),
                itemBuilder: (_) => [
                  const PopupMenuItem(value: '', child: Text('All strokes')),
                  for (final s in strokes)
                    PopupMenuItem(value: s, child: Text(kStrokeLabels[s] ?? s)),
                ],
                child: Chip(
                  avatar: const Icon(Icons.filter_list, size: 16),
                  label: Text(_stroke == null ? 'All strokes' : kStrokeLabels[_stroke] ?? _stroke!),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: hits.isEmpty
              ? const MessageView(icon: Icons.filter_alt_off, message: 'No hits match the filter')
              : ListView.builder(
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
      ],
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
    final text = Theme.of(context).textTheme;
    final stroke = kStrokeLabels[hit.stroke] ?? 'Unclassified';
    final player = playerLabel(hit.who);
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
                color: selected ? a.accent.withValues(alpha: 0.14) : null,
                borderRadius: BorderRadius.circular(10),
                border: selected ? Border.all(color: a.accentInk.withValues(alpha: 0.5)) : null,
              ),
              child: LayoutBuilder(
                builder: (context, box) {
                  final wide = box.maxWidth >= 620;
                  return Row(
                    children: [
                      const SizedBox(width: Spacing.md),
                      SizedBox(
                        width: 58,
                        child: Text(
                          formatClock(hit.timeS),
                          style: kFigureStyle.copyWith(
                            fontSize: 18,
                            color: selected ? a.accentInk : p.ink,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 52,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                            decoration: BoxDecoration(
                              color: colors.forPlayer(hit.who),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Text(
                              textAlign: TextAlign.center,
                              // N / F, or N1 / N2 / F1 / F2 for a doubles partner.
                              player.replaceAll(RegExp('[a-z ]'), ''),
                              style: TextStyle(
                                color: onColor(colors.forPlayer(hit.who)),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hit.uncertain ? '$stroke ?' : stroke,
                              style: text.titleSmall?.copyWith(
                                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                              ),
                            ),
                            if (details.isNotEmpty)
                              Text(
                                details,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: p.text2, fontSize: 13),
                              ),
                          ],
                        ),
                      ),
                      if (wide && speed != null && speedColor != null) ...[
                        const SizedBox(width: Spacing.md),
                        ExcludeSemantics(
                          child: Container(
                            width: 64,
                            height: 4,
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: a.track,
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: FractionallySizedBox(
                              widthFactor: (speed / 300).clamp(0.04, 1.0),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: speedColor,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      IconButton(
                        tooltip: 'Details',
                        color: p.text3,
                        icon: const Icon(Icons.chevron_right),
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
            '${playerLabel(hit.who)} player · ${formatClock(hit.timeS)}',
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
