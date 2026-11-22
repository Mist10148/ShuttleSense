import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/responsive/breakpoints.dart';
import '../../../shared/widgets/surfaces.dart';
import 'court_minimap.dart';
import '../../../core/theme/tokens.dart';

/// Arranges the result zones for phone, tablet and laptop (docs/ARCHITECTURE.md §4).
///
/// compact:  video, status, then tabs (Timeline · Minimap · Score, and Coach when given)
/// medium:   video + status + timeline on the left, minimap + score panel on the right
/// expanded: video + status with a side panel on top, full-width timeline below
/// phone landscape (height < 500): video + status on the left, the tabs on the right
class ResultsLayout extends StatelessWidget {
  const ResultsLayout({
    super.key,
    required this.video,
    required this.status,
    required this.timeline,
    required this.minimap,
    required this.scoreboard,
    this.coach,
  });

  final Widget video;
  final Widget status;
  final Widget timeline;
  final Widget minimap;
  final Widget scoreboard;

  /// Session notes and the way into the chat (F21, F22); under the court in the side panel.
  final Widget? coach;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscapePhone =
            constraints.maxHeight < 500 && constraints.maxWidth > constraints.maxHeight;
        if (landscapePhone) return _landscape(context);
        final panel = sidePanelWidth(constraints.maxWidth);
        return switch (Breakpoints.forWidth(constraints.maxWidth)) {
          WindowClass.compact => _compact(context),
          WindowClass.medium => _medium(panel),
          WindowClass.expanded => _expanded(panel),
        };
      },
    );
  }

  /// Minimap + score panel: 30% of the width, kept between 300 and 400 dp
  /// (but never more than 40% on a narrow tablet).
  static double sidePanelWidth(double width) =>
      (width * 0.3).clamp(300.0, 400.0).clamp(0.0, width * 0.4);

  /// The video in a card. The card is only as tall as the video, and the video still gives
  /// up height first when the space around it is short.
  Widget _videoCard() => LayoutBuilder(
    builder: (context, box) => AppCard(
      padding: const EdgeInsets.all(Spacing.md),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: math.max(0, box.maxHeight - 2 * Spacing.md)),
        child: Align(
          heightFactor: 1,
          child: ClipRRect(borderRadius: BorderRadius.circular(Radii.md), child: video),
        ),
      ),
    ),
  );

  Widget _tabs(BuildContext context) => DefaultTabController(
    length: coach == null ? 3 : 4,
    child: Column(
      children: [
        // The stage-2 tabs: an ink pill for the active tab on a grey track.
        Container(
          padding: const EdgeInsets.all(Spacing.xs),
          decoration: BoxDecoration(
            color: AppPalette.of(context).surface2,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: TabBar(
            tabs: [
              const Tab(text: 'Timeline'),
              const Tab(text: 'Minimap'),
              const Tab(text: 'Score'),
              if (coach != null) const Tab(text: 'Coach'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            children: [
              timeline,
              _fitted(
                padding: 24,
                (child) =>
                    SingleChildScrollView(padding: const EdgeInsets.all(Spacing.md), child: child),
                minimap,
              ),
              SingleChildScrollView(padding: const EdgeInsets.all(Spacing.md), child: scoreboard),
              if (coach != null)
                SingleChildScrollView(padding: const EdgeInsets.all(Spacing.md), child: coach),
            ],
          ),
        ),
      ],
    ),
  );

  /// Tells the minimap how tall the space it scrolls in is, so the whole court fits in
  /// it without scrolling (the court is far taller than it is wide).
  Widget _fitted(Widget Function(Widget child) wrap, Widget child, {double padding = 0}) =>
      LayoutBuilder(
        builder: (context, constraints) =>
            CourtMaxHeight(height: constraints.maxHeight - padding, child: wrap(child)),
      );

  /// The court comes first: it is the one card that has to be seen whole, and the notes
  /// above it used to push most of it below the fold.
  Widget _panel() => _fitted(
    (child) => SingleChildScrollView(child: child),
    Column(
      children: [
        minimap,
        const SizedBox(height: Spacing.lg),
        if (coach != null) ...[coach!, const SizedBox(height: Spacing.lg)],
        scoreboard,
      ],
    ),
  );

  Widget _landscape(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: SingleChildScrollView(child: Column(children: [_videoCard(), status])),
      ),
      const SizedBox(width: Spacing.md),
      Expanded(child: _tabs(context)),
    ],
  );

  /// Video and status scroll when a line-call banner or warning makes them taller than
  /// their share, so the tabs never get squeezed out.
  Widget _compact(BuildContext context) {
    return Column(
      children: [
        Flexible(
          flex: 3,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [_videoCard(), status]),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Expanded(flex: 2, child: _tabs(context)),
      ],
    );
  }

  /// The page around the layout gives the outer gutter, so these have none of their own.
  Widget _medium(double panel) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: Column(
            children: [
              // In a short window (1000x540, say) a full-width video would leave the
              // timeline a few pixels, so the video gives up height first.
              Flexible(flex: 3, child: _videoCard()),
              status,
              const SizedBox(height: Spacing.sm),
              Expanded(flex: 2, child: timeline),
            ],
          ),
        ),
        const SizedBox(width: Spacing.lg),
        SizedBox(width: panel, child: _panel()),
      ],
    );
  }

  Widget _expanded(double panel) {
    return Column(
      children: [
        Flexible(
          flex: 3,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: _videoCard()),
                    status,
                  ],
                ),
              ),
              const SizedBox(width: Spacing.xl),
              SizedBox(width: panel, child: _panel()),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Expanded(flex: 2, child: timeline),
      ],
    );
  }
}
