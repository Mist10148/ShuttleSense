import 'package:flutter/material.dart';

import '../../../core/responsive/breakpoints.dart';
import 'court_minimap.dart';

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
        if (landscapePhone) return _landscape();
        final panel = sidePanelWidth(constraints.maxWidth);
        return switch (Breakpoints.forWidth(constraints.maxWidth)) {
          WindowClass.compact => _compact(),
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

  Widget _tabs() => DefaultTabController(
    length: coach == null ? 3 : 4,
    child: Column(
      children: [
        TabBar(
          tabs: [
            const Tab(text: 'Timeline'),
            const Tab(text: 'Minimap'),
            const Tab(text: 'Score'),
            if (coach != null) const Tab(text: 'Coach'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              timeline,
              _fitted(
                padding: 24,
                (child) => SingleChildScrollView(padding: const EdgeInsets.all(12), child: child),
                minimap,
              ),
              SingleChildScrollView(padding: const EdgeInsets.all(12), child: scoreboard),
              if (coach != null)
                SingleChildScrollView(padding: const EdgeInsets.all(12), child: coach),
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
        const SizedBox(height: 16),
        if (coach != null) ...[coach!, const SizedBox(height: 16)],
        scoreboard,
      ],
    ),
  );

  Widget _landscape() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: SingleChildScrollView(child: Column(children: [video, status])),
      ),
      Expanded(child: _tabs()),
    ],
  );

  /// Video and status scroll when a line-call banner or warning makes them taller than
  /// their share, so the tabs never get squeezed out.
  Widget _compact() {
    return Column(
      children: [
        Flexible(
          flex: 3,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [video, status]),
          ),
        ),
        Expanded(flex: 2, child: _tabs()),
      ],
    );
  }

  Widget _medium(double panel) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              children: [
                // In a short window (1000x540, say) a full-width video would leave the
                // timeline a few pixels, so the video gives up height first.
                Flexible(flex: 3, child: video),
                status,
                const SizedBox(height: 8),
                Expanded(flex: 2, child: timeline),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(width: panel, child: _panel()),
        ],
      ),
    );
  }

  Widget _expanded(double panel) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
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
                      Flexible(child: video),
                      status,
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                SizedBox(width: panel, child: _panel()),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(flex: 2, child: timeline),
        ],
      ),
    );
  }
}
