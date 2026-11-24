import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/json.dart';
import '../../shared/widgets/data_display.dart';
import '../../shared/widgets/notice.dart';
import '../../shared/widgets/surfaces.dart';
import '../../shared/widgets/tactile.dart';
import '../../ui/depth.dart';
import 'practice_followup.dart';

enum _Section {
  summary('Overall Summary', Icons.summarize_outlined),
  details('Detailed Analysis', Icons.analytics_outlined),
  questions('Follow-up Questions', Icons.forum_outlined);

  const _Section(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// The AI Coach's report for one practice video: an overall summary, the detailed evidence
/// behind it and follow-up questions. It only presents what the backend report holds.
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
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    final body = switch (section) {
      _Section.summary => _summary(context, report, evidence, guidance, points, drills, moments),
      _Section.details => _details(
        context,
        report,
        evidence,
        guidance,
        points,
        drills,
        moments,
        sources,
      ),
      _Section.questions =>
        blocked == null
            ? const SizedBox.shrink()
            : NoticeBanner(message: blocked, icon: Icons.lock_outline_rounded),
    };

    return AppCard(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: Spacing.md,
        children: [
          _header(context, widget.report?['generated_by'] as String?),
          // The three views on one line at a readable 13 px. Icons are added when they fit
          // with every label whole; only a phone-narrow panel takes two-line labels.
          LayoutBuilder(
            builder: (context, box) {
              final style = Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(fontSize: 13, fontWeight: FontWeight.w600);
              final widest = [
                for (final item in _Section.values)
                  (TextPainter(
                    text: TextSpan(text: item.label, style: style),
                    textDirection: TextDirection.ltr,
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout()).width,
              ].reduce(math.max);
              // Each segment: label, 24 dp padding, and with an icon 16 + 6 more; tray 8.
              final withIcons = (widest + 24 + 22) * _Section.values.length + 8 <= box.maxWidth;
              final oneLine = (widest + 24) * _Section.values.length + 8 <= box.maxWidth;
              return SizedBox(
                width: box.maxWidth,
                child: DepthSegmented<_Section>(
                  compact: true,
                  wrapLabels: !oneLine,
                  segments: [
                    for (final item in _Section.values)
                      ButtonSegment(
                        value: item,
                        icon: withIcons ? Icon(item.icon) : null,
                        label: Text(item.label),
                      ),
                  ],
                  selected: {section},
                  onSelectionChanged: (s) => setState(() => section = s.first),
                ),
              );
            },
          ),
          ..._status(context),
          AnimatedSwitcher(
            duration: reduce ? Duration.zero : const Duration(milliseconds: 200),
            switchInCurve: Curves.easeOutCubic,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [
                for (final p in previous) Positioned(left: 0, right: 0, top: 0, child: p),
                ?current,
              ],
            ),
            child: KeyedSubtree(key: ValueKey(section), child: body),
          ),
          // Kept alive across views, so a draft question survives switching away and back.
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

  // ---------------------------------------------------------------- header and status

  Widget _header(BuildContext context, String? generatedBy) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final (label, tone) = switch (generatedBy) {
      'gemini' => ('Gemini', NoticeTone.info),
      'claude' => ('Claude', NoticeTone.info),
      'rules' => ('Rules-based', NoticeTone.warning),
      _ => (null, NoticeTone.info),
    };
    return Row(
      children: [
        const IconWell(icon: Icons.auto_awesome_rounded, size: 40, iconSize: 20),
        const SizedBox(width: Spacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI Coach',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
              ),
              Text(
                'Feedback from this video',
                style: text.bodySmall?.copyWith(color: p.text3),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (label != null) _Badge(label: label, color: NoticeBanner.colorFor(context, tone)),
      ],
    );
  }

  List<Widget> _status(BuildContext context) => [
    if (widget.stale)
      const NoticeBanner(
        tone: NoticeTone.warning,
        icon: Icons.edit_note_rounded,
        message: 'Unsaved event changes are not included in this guide.',
      ),
    if (widget.loading)
      const _Preparing()
    else if (widget.error != null)
      NoticeBanner(
        tone: NoticeTone.error,
        message: 'Could not load the coaching guide: ${widget.error}',
        actionLabel: 'Retry coaching guide',
        onAction: widget.onRetry,
      )
    else if (widget.report?['generated_by'] == 'rules')
      NoticeBanner(
        tone: NoticeTone.warning,
        icon: Icons.rule_rounded,
        title: 'Rules-based guide',
        message: switch (widget.report?['fallback_reason']) {
          'rate_limited' => 'The AI coach is rate-limited or its quota is exhausted.',
          'key_rejected' => 'The AI provider rejected the backend key.',
          'no_provider' => 'No AI provider is configured.',
          'insufficient_evidence' => 'Not enough usable evidence to generate an AI guide.',
          _ => 'The AI guide is temporarily unavailable.',
        },
        actionLabel:
            widget.report?['fallback_reason'] != 'insufficient_evidence' &&
                (widget.report?['fallback_reason'] != 'no_provider' || widget.canAsk)
            ? 'Retry AI guide'
            : null,
        onAction: widget.onRetry,
      ),
  ];

  // ---------------------------------------------------------------- overall summary

  Widget _summary(
    BuildContext context,
    Json report,
    List<Json> evidence,
    List<Json> guidance,
    List<Json> points,
    List<Json> drills,
    List<Json> moments,
  ) {
    final text = Theme.of(context).textTheme;
    final p = AppPalette.of(context);
    final summary = report['summary'] as String?;
    final overview = report['ai_overall_guidance'] as String?;
    final session = report['session_overview'] as Json? ?? const {};
    final momentCount = {
      for (final item in evidence) ?(item['moment_s'] as num?),
      for (final point in points) ...(point['moments'] as List? ?? const []).whereType<num>(),
      for (final moment in moments) ?(moment['time_s'] as num?),
    }.length;
    final insufficient = report['fallback_reason'] == 'insufficient_evidence' && evidence.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Spacing.md,
      children: [
        if (overview != null || summary != null)
          _Lead(lead: overview ?? summary!, detail: overview != null ? summary : null),
        if (_overviewChips(context, session) case final chips when chips.isNotEmpty)
          Wrap(spacing: Spacing.sm, runSpacing: Spacing.sm, children: chips),
        if (insufficient)
          const _Tips(
            title: 'To get a full report',
            tips: [
              'Use a steady camera with the whole player in frame.',
              'Choose a clear frame when you select yourself.',
              'Good light and less motion blur help the pose tracking.',
            ],
          ),
        if (points.isNotEmpty)
          _FocusCard(
            kicker: 'Focus next',
            badge: '1',
            title: 'Priority: ${points.first['title']}',
            body: points.first['explanation'] as String?,
          ),
        if (drills.isNotEmpty)
          _FocusCard(
            kicker: 'Try next',
            icon: Icons.fitness_center_rounded,
            title: 'Try next: ${drills.first['title']}',
            body: drills.first['instruction'] as String?,
          )
        else if (guidance.isNotEmpty)
          _FocusCard(
            kicker: 'Rules-based guidance',
            icon: Icons.tips_and_updates_outlined,
            title: null,
            body: guidance.first['text'] as String?,
          ),
        if (evidence.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: _Figure(label: 'Observations', value: '${evidence.length}'),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: _Figure(label: 'Moments', value: '$momentCount'),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: _Figure(label: 'Sources', value: '${_items(report['sources']).length}'),
              ),
            ],
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => setState(() => section = _Section.details),
              icon: const Icon(Icons.arrow_forward_rounded, size: 18),
              iconAlignment: IconAlignment.end,
              label: const Text('See supporting evidence'),
            ),
          ),
        ],
        if (summary == null && overview == null && evidence.isEmpty && !widget.loading)
          Text('No coaching summary yet.', style: text.bodyMedium?.copyWith(color: p.text3)),
      ],
    );
  }

  List<Widget> _overviewChips(BuildContext context, Json session) {
    final counts = (session['stroke_counts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final duration = session['duration_s'] as num?;
    final untracked = session['unobserved_frames'] as num? ?? 0;
    final tracked = session['tracked_frames'] as num?;
    return [
      if (duration != null)
        _Chip(icon: Icons.timer_outlined, label: '${formatMinSec(duration)} analysed'),
      for (final MapEntry(key: stroke, value: n) in counts.entries)
        if (n is num && n > 0)
          _Chip(icon: Icons.sports_tennis_rounded, label: '${_title(stroke)} × $n'),
      if (tracked != null)
        _Chip(icon: Icons.person_search_outlined, label: '$tracked frames tracked'),
      if (untracked > 0)
        _Chip(
          icon: Icons.visibility_off_outlined,
          label: '$untracked frames not tracked',
          muted: true,
        ),
      if (session['stopped_early'] == true)
        const _Chip(icon: Icons.stop_circle_outlined, label: 'Stopped early', muted: true),
    ];
  }

  // ---------------------------------------------------------------- detailed analysis

  Widget _details(
    BuildContext context,
    Json report,
    List<Json> evidence,
    List<Json> guidance,
    List<Json> points,
    List<Json> drills,
    List<Json> moments,
    Map<Object?, Json> sources,
  ) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final linked = {
      for (final point in points) ...(point['evidence_ids'] as List? ?? const []),
      for (final moment in moments) moment['evidence_id'],
    };
    final others = [
      for (final item in evidence)
        if (!linked.contains(item['id'])) item,
    ];
    final empty = evidence.isEmpty && points.isEmpty && moments.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Spacing.lg,
      children: [
        if (empty)
          Text(
            'No usable observations are available for this video.',
            style: text.bodyMedium?.copyWith(color: p.text3),
          ),
        if (points.isNotEmpty)
          _Group(
            title: 'Coaching points',
            icon: Icons.flag_outlined,
            children: [
              for (final (i, point) in points.indexed)
                _Item(
                  badge: '${i + 1}',
                  title: '${point['title']}',
                  body: point['explanation'] as String?,
                  children: [
                    for (final item in evidence.where(
                      (item) => (point['evidence_ids'] as List? ?? const []).contains(item['id']),
                    ))
                      _Observation(item: item),
                    _times(point['moments']),
                    ..._sources(point['knowledge_ids'], sources),
                  ],
                ),
            ],
          ),
        if (moments.isNotEmpty)
          _Group(
            title: 'AI feedback at these moments',
            icon: Icons.timeline_rounded,
            children: [
              for (final (i, moment) in moments.indexed)
                _TimelineEntry(
                  last: i == moments.length - 1,
                  time: moment['time_s'] as num?,
                  onSeek: widget.onSeek,
                  children: [
                    if (moment['text'] case final String said) Text(said, style: text.bodyMedium),
                    for (final item in evidence.where(
                      (item) => item['id'] == moment['evidence_id'],
                    ))
                      _Observation(item: item),
                    ..._sources(moment['knowledge_ids'], sources),
                  ],
                ),
            ],
          ),
        if (others.isNotEmpty)
          _Group(
            title: points.isEmpty && moments.isEmpty ? 'Observations' : 'Other observations',
            icon: Icons.visibility_outlined,
            children: [
              for (final item in others)
                _Observation(item: item, trailing: _times([item['moment_s']])),
            ],
          ),
        if (guidance.isNotEmpty && report['generated_by'] == 'rules')
          _Group(
            title: 'Rules-based guidance',
            icon: Icons.tips_and_updates_outlined,
            children: [
              for (final item in guidance)
                _Item(
                  icon: Icons.lightbulb_outline_rounded,
                  title: null,
                  body: item['text'] as String?,
                  children: [_times(item['moments'])],
                ),
            ],
          ),
        if (drills.isNotEmpty)
          _Group(
            title: 'Drills',
            icon: Icons.fitness_center_rounded,
            children: [
              for (final drill in drills)
                _Item(
                  icon: Icons.fitness_center_rounded,
                  title: '${drill['title']}',
                  body: drill['instruction'] as String?,
                  children: [
                    _times(drill['moments']),
                    ..._sources(drill['knowledge_ids'], sources),
                  ],
                ),
            ],
          ),
        if (widget.unavailableObservations.isNotEmpty)
          _Group(
            title: 'Not measured',
            icon: Icons.visibility_off_outlined,
            muted: true,
            children: [
              for (final item in widget.unavailableObservations)
                _Observation(
                  item: {...item, 'moment_kind': 'unavailable'},
                  trailing: _times([item['moment_s']]),
                ),
            ],
          ),
        if (report['limitation'] case final String limitation)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: p.text3),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Text(limitation, style: text.bodySmall?.copyWith(color: p.text3)),
              ),
            ],
          ),
      ],
    );
  }

  Widget _times(dynamic values) {
    final times = (values as List? ?? const []).whereType<num>().toList();
    if (times.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Spacing.xs + 2,
      runSpacing: Spacing.xs + 2,
      children: [
        for (final value in times)
          TimePill(label: formatMinSec(value), onTap: () => widget.onSeek(value.toDouble())),
      ],
    );
  }

  Iterable<Widget> _sources(dynamic ids, Map<Object?, Json> sources) sync* {
    for (final id in ids as List? ?? const []) {
      final source = sources[id];
      if (source == null) continue;
      yield _Source(title: 'Source: ${source['title'] ?? id}', text: '${source['text'] ?? ''}');
    }
  }
}

List<Json> _items(dynamic value) => (value as List? ?? const []).whereType<Json>().toList();

String _title(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' ');

// ------------------------------------------------------------------ small building blocks

class _Preparing extends StatelessWidget {
  const _Preparing();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: Spacing.sm,
    children: [
      Row(
        children: [
          SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: TactileTokens.of(context).primary,
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Flexible(
            child: Text(
              'Preparing your coaching summary...',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
      const Skeleton(height: 16, width: double.infinity),
      const Skeleton(height: 16, width: 260),
      const Skeleton(height: 64, width: double.infinity),
    ],
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + 2, vertical: Spacing.xs),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(Radii.pill),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: AppPalette.of(context).ink,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// The headline of the summary: the coach's overall guidance in a larger type, with the
/// plain session summary under it.
class _Lead extends StatelessWidget {
  const _Lead({required this.lead, this.detail});

  final String lead;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [t.primary.withValues(alpha: 0.14), t.primary.withValues(alpha: 0.04)],
        ),
        border: Border.all(color: t.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Spacing.sm,
        children: [
          Icon(Icons.format_quote_rounded, color: t.primary, size: 26),
          Text(
            lead,
            style: text.titleMedium?.copyWith(
              height: 1.45,
              color: p.ink,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (detail != null) Text(detail!, style: text.bodyMedium?.copyWith(color: p.text2)),
        ],
      ),
    );
  }
}

/// A raised card with a coloured edge: the one thing to focus on, or the drill to try.
class _FocusCard extends StatelessWidget {
  const _FocusCard({
    required this.kicker,
    required this.title,
    required this.body,
    this.badge,
    this.icon,
  });

  final String kicker;
  final String? title;
  final String? body;
  final String? badge;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final accent = badge != null ? t.primary : StatusColors.of(context).inCall;
    return InsetBox(
      radius: Radii.lg,
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 4,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(Radii.lg)),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Spacing.md + 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                      child: badge != null
                          ? Text(
                              badge!,
                              style: TextStyle(color: onColor(accent), fontWeight: FontWeight.w700),
                            )
                          : Icon(icon, size: 16, color: onColor(accent)),
                    ),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 2,
                        children: [
                          Text(
                            kicker,
                            style: text.labelMedium?.copyWith(
                              color: accent,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3,
                            ),
                          ),
                          if (title != null)
                            Text(
                              title!,
                              style: text.titleSmall?.copyWith(
                                color: p.ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          if (body != null)
                            Text(body!, style: text.bodyMedium?.copyWith(color: p.text2)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return InsetBox(
      radius: Radii.md,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md, vertical: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              label,
              maxLines: 1,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.text3),
            ),
          ),
          Text(value, style: kFigureStyle.copyWith(fontSize: 20, color: p.ink)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, this.muted = false});

  final IconData icon;
  final String label;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final color = muted ? p.text3 : p.text2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + 2, vertical: 6),
      decoration: BoxDecoration(
        color: p.surface2.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: p.hairline ?? p.surface2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tips extends StatelessWidget {
  const _Tips({required this.title, required this.tips});

  final String title;
  final List<String> tips;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return InsetBox(
      radius: Radii.lg,
      padding: const EdgeInsets.all(Spacing.md + 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Spacing.xs + 2,
        children: [
          Text(title, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          for (final tip in tips)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: StatusColors.of(context).inCall,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(tip, style: text.bodyMedium?.copyWith(color: p.text2)),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// A titled group in the detailed analysis.
class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.icon,
    required this.children,
    this.muted = false,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: Spacing.sm,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: muted ? p.text3 : TactileTokens.of(context).primary),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                title.toUpperCase(),
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: muted ? p.text3 : p.text2,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ),
        ...children,
      ],
    );
  }
}

/// One coaching point, guidance tip or drill: a recessed card with a number or icon.
class _Item extends StatelessWidget {
  const _Item({
    required this.title,
    required this.body,
    this.badge,
    this.icon,
    this.children = const [],
  });

  final String? title;
  final String? body;
  final String? badge;
  final IconData? icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return InsetBox(
      radius: Radii.lg,
      padding: const EdgeInsets.all(Spacing.md + 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.primary.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: badge != null
                ? Text(
                    badge!,
                    style: TextStyle(color: t.primary, fontWeight: FontWeight.w700),
                  )
                : Icon(icon, size: 16, color: t.primary),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: Spacing.sm,
              children: [
                if (title != null)
                  Text(title!, style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                if (body != null) Text(body!, style: text.bodyMedium?.copyWith(color: p.text2)),
                ...children,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A point on the AI moments timeline: a dot and line on the left, the time and text on the
/// right.
class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.time,
    required this.onSeek,
    required this.children,
    required this.last,
  });

  final num? time;
  final ValueChanged<double> onSeek;
  final List<Widget> children;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final t = TactileTokens.of(context);
    final p = AppPalette.of(context);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: t.primary,
                    border: Border.all(color: p.surface, width: 2),
                  ),
                ),
                if (!last)
                  Expanded(child: Container(width: 2, color: t.primary.withValues(alpha: 0.25))),
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: Spacing.xs + 2,
                children: [
                  if (time case final at?)
                    TimePill(label: formatMinSec(at), onTap: () => onSeek(at.toDouble())),
                  ...children,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One measured observation: an icon for its kind, what was seen and the value.
class _Observation extends StatelessWidget {
  const _Observation({required this.item, this.trailing});

  final Json item;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    final (label, icon) = switch (item['moment_kind']) {
      'marked' => ('Marked pose observation', Icons.bookmark_outline_rounded),
      'movement' => ('Movement observation', Icons.directions_run_rounded),
      'snapshot' => ('Pose snapshot', Icons.photo_camera_outlined),
      'unavailable' => ('Unavailable', Icons.visibility_off_outlined),
      _ when '${item['id']}'.startsWith('analysis-note-') => (
        'Automated analysis note',
        Icons.auto_fix_high_outlined,
      ),
      _ => ('Pose observation', Icons.accessibility_new_rounded),
    };
    final value = [item['value'], item['unit']].where((part) => part != null).join(' ');
    final muted = item['moment_kind'] == 'unavailable';
    return Container(
      padding: const EdgeInsets.all(Spacing.sm + 2),
      decoration: BoxDecoration(
        color: p.surface2.withValues(alpha: muted ? 0.3 : 0.55),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.hairline ?? p.surface2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: Spacing.xs + 2,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: muted ? p.text3 : p.text2),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: text.labelSmall?.copyWith(color: p.text3)),
                    Text(
                      '${item['description'] ?? ''}',
                      style: text.bodyMedium?.copyWith(color: muted ? p.text3 : p.ink),
                    ),
                  ],
                ),
              ),
              if (value.isNotEmpty) ...[
                const SizedBox(width: Spacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 3),
                  decoration: BoxDecoration(
                    color: TactileTokens.of(context).primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Text(
                    value,
                    style: kFigureStyle.copyWith(fontSize: 13, color: p.ink, letterSpacing: 0),
                  ),
                ),
              ],
            ],
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A source the coach drew on: its title, opening to the excerpt.
class _Source extends StatelessWidget {
  const _Source({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 30, bottom: Spacing.sm),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        leading: Icon(Icons.menu_book_outlined, size: 18, color: p.text3),
        title: Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: p.text2, fontWeight: FontWeight.w600),
        ),
        children: [
          Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.text2)),
        ],
      ),
    );
  }
}
