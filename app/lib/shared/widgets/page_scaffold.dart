import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';

/// Standard page: app bar + scrollable body with responsive gutters and a max width.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.maxWidth = 720,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final gutter = Breakpoints.gutter(Breakpoints.of(context));
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(gutter),
          children: [
            MaxWidth(
              maxWidth: maxWidth,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ],
        ),
      ),
    );
  }
}
