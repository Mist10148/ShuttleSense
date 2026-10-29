import 'package:flutter/material.dart';

import '../../../core/responsive/breakpoints.dart';

/// Arranges the result zones for phone, tablet and laptop (docs/ARCHITECTURE.md §4).
///
/// compact:  video, status, then tabs (Timeline · Minimap · Score)
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
  });

  final Widget video;
  final Widget status;
  final Widget timeline;
  final Widget minimap;
  final Widget scoreboard;

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
    length: 3,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: 'Timeline'),
            Tab(text: 'Minimap'),
            Tab(text: 'Score'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              timeline,
              SingleChildScrollView(padding: const EdgeInsets.all(12), child: minimap),
              SingleChildScrollView(padding: const EdgeInsets.all(12), child: scoreboard),
            ],
          ),
        ),
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

  Widget _compact() {
    return Column(
      children: [
        video,
        status,
        Expanded(child: _tabs()),
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
                video,
                status,
                const SizedBox(height: 8),
                Expanded(child: timeline),
              ],
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: panel,
            child: SingleChildScrollView(
              child: Column(children: [minimap, const SizedBox(height: 16), scoreboard]),
            ),
          ),
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
                SizedBox(
                  width: panel,
                  child: SingleChildScrollView(
                    child: Column(children: [minimap, const SizedBox(height: 16), scoreboard]),
                  ),
                ),
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
