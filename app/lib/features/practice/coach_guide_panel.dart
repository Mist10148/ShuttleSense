import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../shared/widgets/surfaces.dart';

/// A self-contained, replaceable presentation for the generated practice guide.
class CoachGuidePanel extends StatefulWidget {
  const CoachGuidePanel({
    super.key,
    required this.report,
    required this.loading,
    required this.error,
    required this.stale,
    required this.onRetry,
    required this.onSeek,
  });
  final Map<String, dynamic>? report;
  final bool loading, stale;
  final String? error;
  final VoidCallback onRetry;
  final void Function(double seconds) onSeek;

  @override
  State<CoachGuidePanel> createState() => _CoachGuidePanelState();
}

class _CoachGuidePanelState extends State<CoachGuidePanel> {
  bool arrived = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => arrived = true);
    });
  }

  String time(num value) {
    final seconds = value.floor();
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final sourceItems = <String, Map>{
      for (final source in (report?['sources'] as List? ?? const []))
        if (source is Map && source['id'] is String) source['id'] as String: source,
    };
    Widget times(List<dynamic> moments) => Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final moment in moments.whereType<num>())
          ActionChip(label: Text(time(moment)), onPressed: () => widget.onSeek(moment.toDouble())),
      ],
    );
    Widget sources(dynamic ids) {
      final list = (ids as List? ?? const []).map((id) => sourceItems['$id']).whereType<Map>();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final source in list)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Text(
                'Source: ${source['title'] ?? source['id']}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              children: [Text('${source['text'] ?? ''}')],
            ),
        ],
      );
    }

    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AppCard(
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 46,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 36),
                    child: (arrived || reduceMotion)
                        ? const Text('AI Coach', style: TextStyle(fontWeight: FontWeight.bold))
                        : const SizedBox.shrink(),
                  ),
                ),
              ),
              if (widget.stale) const Text('Unsaved event changes are not included in this guide.'),
              if (widget.loading) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: Spacing.sm),
                const Text('Preparing your coaching summary...'),
              ] else if (widget.error != null) ...[
                Text('Could not load the coaching guide: ${widget.error}'),
                TextButton(onPressed: widget.onRetry, child: const Text('Retry coaching guide')),
              ] else if (report != null && report['generated_by'] == 'rules') ...[
                if (report['fallback_reason'] == 'rate_limited')
                  const Text(
                    'Gemini is rate-limited or its quota is exhausted. Try again later; the rules-based coaching is below.',
                  )
                else if (report['fallback_reason'] == 'key_rejected')
                  const Text(
                    'The configured AI provider rejected the key. Check the backend configuration; the rules-based coaching is below.',
                  )
                else if (report['fallback_reason'] == 'no_provider')
                  const Text('No AI provider is configured. The rules-based coaching is below.')
                else if (report['fallback_reason'] == 'insufficient_evidence')
                  const Text('Not enough usable analysis to generate an AI guide.')
                else
                  const Text(
                    'AI guide is temporarily unavailable. The rules-based coaching is below.',
                  ),
                if (report['fallback_reason'] != 'insufficient_evidence')
                  TextButton(onPressed: widget.onRetry, child: const Text('Retry AI guide')),
              ] else if (report != null) ...[
                Text(
                  '${report['ai_overall_guidance'] ?? 'Review the linked coaching moments below.'}',
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  'Generated by: ${report['generated_by']}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final point in (report['coaching_points'] as List? ?? const [])) ...[
                  const SizedBox(height: Spacing.md),
                  Text('${point['title']}', style: Theme.of(context).textTheme.titleSmall),
                  Text('${point['explanation']}'),
                  times((point['moments'] as List?) ?? const []),
                  sources(point['knowledge_ids']),
                ],
                if ((report['coaching_points'] as List? ?? const []).isEmpty)
                  for (final item in (report['ai_moment_guidance'] as List? ?? const [])) ...[
                    const SizedBox(height: Spacing.md),
                    Text('${item['text']}'),
                    times([if (item['time_s'] is num) item['time_s']]),
                    sources(item['knowledge_ids']),
                  ],
                if ((report['drills'] as List? ?? const []).isNotEmpty) ...[
                  const SizedBox(height: Spacing.md),
                  Text('What to practice next', style: Theme.of(context).textTheme.titleSmall),
                  for (final drill in (report['drills'] as List)) ...[
                    const SizedBox(height: Spacing.sm),
                    Text('${drill['title']}'),
                    Text('${drill['instruction']}'),
                    times((drill['moments'] as List?) ?? const []),
                    sources(drill['knowledge_ids']),
                  ],
                ],
                const SizedBox(height: Spacing.md),
                Text('${report['limitation'] ?? ''}', style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedAlign(
                duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 650),
                curve: Curves.easeInOutCubic,
                alignment: arrived || reduceMotion ? Alignment.topLeft : Alignment.center,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Icon(Icons.auto_awesome, color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
