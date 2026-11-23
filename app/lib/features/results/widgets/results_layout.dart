import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import 'court_minimap.dart';
import '../../../shared/widgets/tactile.dart';
import '../../../ui/depth.dart';

/// Arranges the results screen (docs/ARCHITECTURE.md §4).
///
/// expanded:  left, the video, its controls and right under them the sections (Timeline,
///            Stats, Score, Coach), all in one screen with no page scroll; right, a column
///            with the shot now, the court and the players, always in view
/// medium, compact:  one scrolling page: video, controls, shot, court, players, sections
/// phone landscape (height < 500): the stage on the left, the sections on the right
class ResultsLayout extends StatelessWidget {
  const ResultsLayout({
    super.key,
    required this.video,
    required this.status,
    required this.timeline,
    required this.minimap,
    required this.scoreboard,
    this.coach,
    this.shot,
    this.compactShot,
    this.stats,
    this.players,
  });

  final Widget video;

  /// Playback controls, the shot marks and any line-call banner, under the video.
  final Widget status;
  final Widget timeline;

  /// The court card: beside the video on a laptop, under the shot on a phone.
  final Widget minimap;
  final Widget scoreboard;

  /// Session notes and the way into the chat (F21, F22).
  final Widget? coach;

  /// The current shot, top of the right column.
  final Widget? shot;

  /// The same for a phone or a narrower window; [shot] when not given.
  final Widget? compactShot;

  /// Headline numbers and the stroke chart.
  final Widget? stats;

  /// Each player's movement so far.
  final Widget? players;

  /// Height the court card is given in the right column: enough for the court on its side.
  static const double courtCardHeight = 400;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscapePhone =
            constraints.maxHeight < 500 && constraints.maxWidth > constraints.maxHeight;
        if (landscapePhone) return _landscape(context);
        return switch (Breakpoints.forWidth(constraints.maxWidth)) {
          WindowClass.compact || WindowClass.medium => _page(context, constraints),
          WindowClass.expanded => _expanded(context, constraints),
        };
      },
    );
  }

  /// Width of the right column: 30% of the window, 360 to 440 dp.
  static double sidePanelWidth(double width) => (width * 0.3).clamp(360.0, 440.0);

  Widget get _smallShot => compactShot ?? shot ?? const SizedBox.shrink();

  Widget _court(double height) => RepaintBoundary(
    child: CourtMaxHeight(height: height, child: minimap),
  );

  /// The shot, the court and the players, top to bottom.
  List<Widget> _now(Widget shotPanel, double courtHeight) => [
    RepaintBoundary(child: shotPanel),
    const SizedBox(height: Spacing.md),
    _court(courtHeight),
    if (players != null) ...[const SizedBox(height: Spacing.md), players!],
  ];

  Widget _sections(BuildContext context) {
    Widget scroll(Widget child) =>
        SingleChildScrollView(padding: const EdgeInsets.all(Spacing.lg), child: child);
    final sections = <(String, Widget)>[
      ('Timeline', timeline),
      if (stats != null) ('Stats', scroll(stats!)),
      ('Score', scroll(scoreboard)),
      if (coach != null) ('Coach', scroll(coach!)),
    ];
    return DefaultTabController(
      length: sections.length,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: raisedGradient(TactileTokens.of(context)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: TactileTokens.of(context).rim),
          boxShadow: raisedShadows(TactileTokens.of(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.sm, Spacing.sm, Spacing.sm, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InsetBox(
                  radius: Radii.pill,
                  padding: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelPadding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
                      tabs: [for (final (label, _) in sections) Tab(text: label, height: 38)],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [for (final (_, child) in sections) child],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoFrame() => RepaintBoundary(
    child: ClipRRect(borderRadius: BorderRadius.circular(16), child: video),
  );

  /// One screen: nothing scrolls but the sections and, on a short window, the right column.
  Widget _expanded(BuildContext context, BoxConstraints box) {
    final side = sidePanelWidth(box.maxWidth);
    // The video takes what it needs up to 60% of the height; the sections keep the rest,
    // so their tabs sit right under the controls.
    final videoMax = math.max(160.0, box.maxHeight * 0.6);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The sections keep a readable height (never a sliver under a tall video); on a
        // short window the left column scrolls a little to reach them.
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: videoMax),
                  child: Align(heightFactor: 1, child: _videoFrame()),
                ),
                status,
                const SizedBox(height: Spacing.md),
                SizedBox(height: math.max(440.0, box.maxHeight * 0.55), child: _sections(context)),
              ],
            ),
          ),
        ),
        const SizedBox(width: Spacing.lg + Spacing.xs),
        SizedBox(
          width: side,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _now(shot ?? _smallShot, courtCardHeight),
            ),
          ),
        ),
      ],
    );
  }

  /// Phones and tablets: one page, the court on its side across the width.
  Widget _page(BuildContext context, BoxConstraints box) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _videoFrame(),
        status,
        const SizedBox(height: Spacing.md),
        ..._now(_smallShot, math.min(courtCardHeight, box.maxWidth * 0.75 + 60)),
        const SizedBox(height: Spacing.lg),
        SizedBox(height: (box.maxHeight * 0.8).clamp(380.0, 760.0), child: _sections(context)),
      ],
    ),
  );

  Widget _landscape(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _videoFrame(),
              status,
              const SizedBox(height: Spacing.md),
              ..._now(_smallShot, courtCardHeight),
            ],
          ),
        ),
      ),
      const SizedBox(width: Spacing.md),
      Expanded(child: _sections(context)),
    ],
  );
}
