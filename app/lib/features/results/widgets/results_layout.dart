import 'package:flutter/material.dart';

import '../../../core/responsive/breakpoints.dart';

/// Arranges the result zones for phone, tablet and laptop (docs/ARCHITECTURE.md §4).
///
/// compact:  video, status, then tabs (Timeline · Minimap · Score)
/// medium:   video + status + timeline on the left, minimap + score panel on the right
/// expanded: video + status with a side panel on top, full-width timeline below
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
      builder: (context, constraints) => switch (Breakpoints.forWidth(constraints.maxWidth)) {
        WindowClass.compact => _compact(),
        WindowClass.medium => _medium(),
        WindowClass.expanded => _expanded(),
      },
    );
  }

  Widget _compact() {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          video,
          status,
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
  }

  Widget _medium() {
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
            width: 260,
            child: SingleChildScrollView(
              child: Column(children: [minimap, const SizedBox(height: 16), scoreboard]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _expanded() {
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
                  width: 340,
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
