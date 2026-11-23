import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../core/theme/app_theme.dart';
import 'court_minimap.dart';
import '../../../shared/widgets/smooth_scroll.dart';
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
    this.timelineActions,
  });

  /// Shown at the right end of the tab row while the Timeline tab is open (its filters).
  final Widget? timelineActions;

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
  static const double courtCardHeight = 440;

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

  /// Width of the right column: a third of the window, 380 to 500 dp (a wider court).
  static double sidePanelWidth(double width) => (width * 0.33).clamp(380.0, 500.0);

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

  /// The section tabs. Stats, Score and Coach are as tall as their content and the page
  /// scrolls to read them; the Timeline keeps [timelineHeight] and scrolls its own rows (it
  /// follows the playing stroke).
  Widget _sections(BuildContext context, {required double timelineHeight}) {
    Widget pad(Widget child) => Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.xl, Spacing.lg, Spacing.xl, Spacing.xl),
      child: child,
    );
    final sections = <(String, Widget)>[
      ('Timeline', SizedBox(height: timelineHeight, child: timeline)),
      if (stats != null) ('Stats', pad(stats!)),
      ('Score', pad(scoreboard)),
      if (coach != null) ('Coach', pad(coach!)),
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
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, Spacing.md, 0),
              // The Timeline's filters share the tab row when there is room, else they get
              // a row of their own under the tabs; nothing is squeezed or overlaps.
              child: LayoutBuilder(
                builder: (context, box) {
                  final tray = InsetBox(
                    radius: 14,
                    padding: const EdgeInsets.all(4),
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      labelPadding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
                      tabs: [for (final (label, _) in sections) Tab(text: label, height: 36)],
                    ),
                  );
                  final actions = timelineActions == null
                      ? null
                      : _TimelineOnly(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: timelineActions,
                          ),
                        );
                  if (actions == null) {
                    return Align(alignment: AlignmentDirectional.centerStart, child: tray);
                  }
                  // Tabs on the left, the filters at the right end of the same row.
                  if (box.maxWidth >= 640) {
                    return Row(
                      children: [
                        tray,
                        const SizedBox(width: Spacing.md),
                        // Pinned to the right edge; shrinks a little rather than overflow.
                        Expanded(
                          child: Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: AlignmentDirectional.centerEnd,
                              child: _TimelineOnly(child: timelineActions!),
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      tray,
                      const SizedBox(height: Spacing.sm),
                      Align(alignment: AlignmentDirectional.centerStart, child: actions),
                    ],
                  );
                },
              ),
            ),
            _FadingTabView(children: [for (final (_, child) in sections) child]),
          ],
        ),
      ),
    );
  }

  /// The video sits in a raised frame, like a screen set into the console.
  Widget _videoFrame() => Builder(
    builder: (context) {
      final t = TactileTokens.of(context);
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: raisedGradient(t),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: t.rim),
          boxShadow: raisedShadows(t, depth: 0.6),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm + 2),
          child: RepaintBoundary(
            child: ClipRRect(borderRadius: BorderRadius.circular(12), child: video),
          ),
        ),
      );
    },
  );

  /// The left column scrolls: the video, its controls and the sections under them, each
  /// section as tall as it needs. The right column (shot, court, players) scrolls on its own.
  Widget _expanded(BuildContext context, BoxConstraints box) {
    final side = sidePanelWidth(box.maxWidth);
    // The video takes up to 58% of the height; the tab row still starts in view under it.
    final videoMax = math.max(160.0, box.maxHeight * 0.58);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The sections keep a readable height (never a sliver under a tall video); on a
        // short window the left column scrolls a little to reach them.
        Expanded(
          child: SmoothScroll(
            builder: (context, controller) => SingleChildScrollView(
              controller: controller,
              // Room under the last section so its end is never flush with the window.
              padding: const EdgeInsets.only(bottom: Spacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The frame fits the video itself, centred in the column (no dark bars).
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: videoMax),
                    child: Align(heightFactor: 1, child: _videoFrame()),
                  ),
                  status,
                  const SizedBox(height: Spacing.md),
                  _sections(context, timelineHeight: (box.maxHeight * 0.6).clamp(420.0, 640.0)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: Spacing.lg + Spacing.xs),
        SizedBox(
          width: side,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: Spacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              // The court gives way on a short window so the players stay in view too.
              children: _now(
                shot ?? _smallShot,
                (box.maxHeight - 440).clamp(300.0, courtCardHeight),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Phones and tablets: one page, the court on its side across the width.
  Widget _page(BuildContext context, BoxConstraints box) => SingleChildScrollView(
    padding: const EdgeInsets.only(bottom: Spacing.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _videoFrame(),
        status,
        const SizedBox(height: Spacing.md),
        ..._now(_smallShot, math.min(courtCardHeight, box.maxWidth * 0.75 + 60)),
        const SizedBox(height: Spacing.lg),
        _sections(context, timelineHeight: (box.maxHeight * 0.7).clamp(380.0, 640.0)),
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
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: Spacing.xl),
          child: _sections(context, timelineHeight: 300),
        ),
      ),
    ],
  );
}

/// The chosen section, faded in (with a small rise) when the tab changes instead of sliding
/// across from the side.
class _FadingTabView extends StatelessWidget {
  const _FadingTabView({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tabs = DefaultTabController.of(context);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, _) {
        final index = tabs.index.clamp(0, children.length - 1);
        final duration = reduce ? Duration.zero : const Duration(milliseconds: 200);
        // The panel grows or shrinks smoothly to the new section's height.
        return AnimatedSize(
          duration: duration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: duration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [
                for (final p in previous) Positioned(left: 0, right: 0, top: 0, child: p),
                ?current,
              ],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.015), end: Offset.zero).animate(animation),
                child: child,
              ),
            ),
            child: KeyedSubtree(key: ValueKey(index), child: children[index]),
          ),
        );
      },
    );
  }
}

/// Shown (and tappable) only while the Timeline tab is open; it keeps its place otherwise so
/// the tab row does not jump.
class _TimelineOnly extends StatelessWidget {
  const _TimelineOnly({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tabs = DefaultTabController.of(context);
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, _) => AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: tabs.index == 0 ? 1 : 0,
        child: IgnorePointer(ignoring: tabs.index != 0, child: child),
      ),
    );
  }
}
