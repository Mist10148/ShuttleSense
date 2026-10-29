import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/message_view.dart';

/// Seeking lands this long before the hit so the swing is visible.
const kSeekLead = Duration(milliseconds: 500);

/// Height of one timeline row, used to auto-scroll to the current hit.
const double kTimelineRowHeight = 72;

/// C3 / FR-C3: one row per hit; tapping a row seeks the video, long-press shows details.
class StrokeTimeline extends StatefulWidget {
  const StrokeTimeline({super.key, required this.hits, this.currentHitId, required this.onSeek});

  final List<Hit> hits;
  final int? currentHitId;

  /// Called with the position to seek to (the hit minus [kSeekLead]).
  final ValueChanged<Duration> onSeek;

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
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              const SizedBox(width: 8),
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
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final colors = PlayerColors.of(context);
    final stroke = kStrokeLabels[hit.stroke] ?? 'Unclassified';
    final player = hit.player == 'near' ? 'Near' : 'Far';
    final details = [
      if (hit.confidence != null) '${(hit.confidence! * 100).round()}%',
      if (hit.speedKmh != null) '~${hit.speedKmh!.round()} km/h (est.)',
      ?hit.tip,
    ].join(' · ');
    final target = hit.position - kSeekLead;
    return Semantics(
      button: true,
      label: '$player player, $stroke at ${formatClock(hit.timeS)}',
      hint: 'Double tap to jump to this hit. Long press for details.',
      excludeSemantics: true,
      // The tile's own actions are excluded with its semantics, so give them back here.
      onTap: () => onSeek(target.isNegative ? Duration.zero : target),
      onLongPress: () => showHitDetails(context, hit),
      child: ListTile(
        selected: selected,
        onTap: () => onSeek(target.isNegative ? Duration.zero : target),
        onLongPress: () => showHitDetails(context, hit),
        leading: CircleAvatar(
          radius: 14,
          backgroundColor: colors.forSide(hit.player),
          child: Text(
            hit.player == 'near' ? 'N' : 'F',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ),
        title: Text(hit.uncertain ? '$stroke ?' : stroke),
        subtitle: details.isEmpty
            ? null
            : Text(details, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(formatClock(hit.timeS)),
            IconButton(
              tooltip: 'Details',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showHitDetails(context, hit),
            ),
          ],
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
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          Text(
            '${kStrokeLabels[hit.stroke] ?? 'Unclassified'} · '
            '${hit.player == 'near' ? 'Near' : 'Far'} player · ${formatClock(hit.timeS)}',
            style: theme.textTheme.titleMedium,
          ),
          if (hit.uncertain)
            Text(
              'Low confidence: the model is unsure about this stroke.',
              style: theme.textTheme.bodySmall,
            ),
          if (probs.isNotEmpty) ...[
            const SizedBox(height: 12),
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
          const SizedBox(height: 16),
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
          const SizedBox(height: 8),
          Text(
            'Heuristic guidance, not professional coaching.',
            style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}
