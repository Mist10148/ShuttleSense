import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../data/models/json.dart';
import '../../shared/widgets/surfaces.dart';
import 'practice_followup.dart';

enum _Section {
  summary('Overall Summary', Icons.summarize_outlined),
  details('Detailed Analysis', Icons.analytics_outlined),
  questions('Follow-up Questions', Icons.forum_outlined);

  const _Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

class CoachGuidePanel extends StatefulWidget {
  const CoachGuidePanel({
    super.key,
    required this.report,
    required this.loading,
    required this.error,
    required this.stale,
    required this.onRetry,
    required this.onSeek,
    this.rulesReport,
    this.unavailableObservations = const [],
    this.canAsk = false,
    this.savedAnalysisPending = false,
    this.conversationEpoch = 0,
    this.onAsk,
    this.onReload,
  });

  final Json? report, rulesReport;
  final List<Json> unavailableObservations;
  final bool loading, stale, canAsk, savedAnalysisPending;
  final int conversationEpoch;
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback? onReload;
  final ValueChanged<double> onSeek;
  final PracticeQuestion? onAsk;

  @override
  State<CoachGuidePanel> createState() => _CoachGuidePanelState();
}

class _CoachGuidePanelState extends State<CoachGuidePanel> {
  _Section section = _Section.summary;

  @override
  Widget build(BuildContext context) {
    final report = widget.report ?? widget.rulesReport ?? const <String, dynamic>{};
    final evidence = _items(report['evidence']);
    final guidance = _items(report['guidance']);
    final points = _items(report['coaching_points']);
    final moments = _items(report['ai_moment_guidance']);
    final drills = _items(report['drills']);
    final sources = {for (final item in _items(report['sources'])) item['id']: item};
    final version = widget.report?['context_version'] as String?;
    final ask = widget.onAsk;
    final blocked = switch ((
      widget.stale,
      widget.savedAnalysisPending,
      widget.loading,
      widget.canAsk,
      version,
    )) {
      (true, _, _, _, _) => 'Save your event changes to ask about the updated video analysis.',
      (_, true, _, _, _) => 'Reload the saved analysis before asking a question.',
      (_, _, true, _, _) => 'Wait for the coaching report to finish loading.',
      (_, _, _, false, _) => 'Follow-up questions require an AI coach provider.',
      (_, _, _, _, null) => 'Load the coaching report to ask about this video.',
      _ when evidence.isEmpty => 'There is not enough visible evidence to answer questions.',
      _ => null,
    };

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Spacing.sm,
        children: [
          Text('AI Coach', style: Theme.of(context).textTheme.titleMedium),
          Wrap(
            spacing: Spacing.xs,
            runSpacing: Spacing.xs,
            children: [
              for (final item in _Section.values)
                ChoiceChip(
                  avatar: Icon(item.icon, size: 16),
                  label: Text(item.label),
                  selected: section == item,
                  onSelected: (_) => setState(() => section = item),
                ),
            ],
          ),
          if (widget.stale) const Text('Unsaved event changes are not included in this guide.'),
          if (widget.loading) ...[
            const LinearProgressIndicator(),
            const Text('Preparing your coaching summary...'),
          ] else if (widget.error != null) ...[
            Text('Could not load the coaching guide: ${widget.error}'),
            TextButton(onPressed: widget.onRetry, child: const Text('Retry coaching guide')),
          ] else if (widget.report?['generated_by'] == 'rules') ...[
            Text(switch (widget.report?['fallback_reason']) {
              'rate_limited' => 'The AI coach is rate-limited or its quota is exhausted.',
              'key_rejected' => 'The AI provider rejected the backend key.',
              'no_provider' => 'No AI provider is configured.',
              'insufficient_evidence' => 'Not enough usable evidence to generate an AI guide.',
              _ => 'The AI guide is temporarily unavailable.',
            }),
            if (widget.report?['fallback_reason'] != 'insufficient_evidence' &&
                (widget.report?['fallback_reason'] != 'no_provider' || widget.canAsk))
              TextButton(onPressed: widget.onRetry, child: const Text('Retry AI guide')),
          ],
          if (section == _Section.summary) ...[
            if (report['summary'] case final String summary) Text(summary),
            if (report['ai_overall_guidance'] case final String overview) Text(overview),
            if (points.isNotEmpty)
              _entry(context, 'Priority: ${points.first['title']}', points.first['explanation']),
            if (drills.isNotEmpty)
              _entry(context, 'Try next: ${drills.first['title']}', drills.first['instruction'])
            else if (guidance.isNotEmpty)
              _entry(context, 'Rules-based guidance', guidance.first['text']),
            if (evidence.isNotEmpty)
              TextButton(
                onPressed: () => setState(() => section = _Section.details),
                child: const Text('See supporting evidence'),
              ),
          ],
          if (section == _Section.details) ...[
            if (evidence.isEmpty && points.isEmpty && moments.isEmpty)
              const Text('No usable observations are available for this video.'),
            for (final point in points) ...[
              _entry(context, '${point['title']}', point['explanation']),
              for (final item in evidence.where(
                (item) => (point['evidence_ids'] as List? ?? const []).contains(item['id']),
              ))
                Text(_observation(item)),
              _times(point['moments']),
              ..._sources(point['knowledge_ids'], sources),
            ],
            for (final moment in moments) ...[
              _entry(context, 'AI feedback at this moment', moment['text']),
              for (final item in evidence.where((item) => item['id'] == moment['evidence_id']))
                Text(_observation(item)),
              _times([moment['time_s']]),
              ..._sources(moment['knowledge_ids'], sources),
            ],
            for (final item in evidence.where(
              (item) =>
                  !points.any(
                    (point) => (point['evidence_ids'] as List? ?? const []).contains(item['id']),
                  ) &&
                  !moments.any((moment) => moment['evidence_id'] == item['id']),
            )) ...[
              Text(_observation(item)),
              _times([item['moment_s']]),
            ],
            if (guidance.isNotEmpty && report['generated_by'] == 'rules')
              for (final item in guidance) ...[
                _entry(context, 'Rules-based guidance', item['text']),
                _times(item['moments']),
              ],
            for (final drill in drills) ...[
              _entry(context, 'Drill: ${drill['title']}', drill['instruction']),
              _times(drill['moments']),
              ..._sources(drill['knowledge_ids'], sources),
            ],
            for (final item in widget.unavailableObservations) ...[
              Text('Unavailable: ${item['description']}'),
              _times([item['moment_s']]),
            ],
            if (report['limitation'] case final String limitation)
              Text(limitation, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (section == _Section.questions && blocked != null) Text(blocked),
          if (version != null && ask != null)
            Visibility(
              visible: section == _Section.questions,
              maintainState: true,
              child: PracticeFollowup(
                key: ValueKey((version, widget.conversationEpoch)),
                version: version,
                enabled: blocked == null,
                suggestions: [
                  if (points.isNotEmpty) 'Why did you flag "${points.first['title']}"?',
                  if (drills.isNotEmpty) 'How should I practice "${drills.first['title']}"?',
                  'What should I focus on next from this video?',
                ],
                onAsk: ask,
                onSeek: widget.onSeek,
                onReload: widget.onReload ?? widget.onRetry,
              ),
            ),
        ],
      ),
    );
  }

  Widget _entry(BuildContext context, String title, Object? text) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: Theme.of(context).textTheme.titleSmall),
      if (text is String) Text(text),
    ],
  );

  String _observation(Json item) {
    final label = item['rule'] != null && '${item['id']}'.startsWith('analysis-note-')
        ? 'Automated analysis note'
        : 'Pose observation';
    final value = [item['value'], item['unit']].where((part) => part != null).join(' ');
    return '$label: ${item['description']}${value.isEmpty ? '' : ' ($value)'}';
  }

  Widget _times(dynamic values) => Wrap(
    spacing: Spacing.xs,
    children: [
      for (final value in (values as List? ?? const []).whereType<num>())
        ActionChip(
          label: Text(
            '${(value ~/ 60).toString().padLeft(2, '0')}:${(value.floor() % 60).toString().padLeft(2, '0')}',
          ),
          onPressed: () => widget.onSeek(value.toDouble()),
        ),
    ],
  );

  Iterable<Widget> _sources(dynamic ids, Map<Object?, Json> sources) sync* {
    for (final id in ids as List? ?? const []) {
      final source = sources[id];
      if (source == null) continue;
      yield ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('Source: ${source['title'] ?? id}'),
        children: [Text('${source['text'] ?? ''}')],
      );
    }
  }
}

List<Json> _items(dynamic value) => (value as List? ?? const []).whereType<Json>().toList();
