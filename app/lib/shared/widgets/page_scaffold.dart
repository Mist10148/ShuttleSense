import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/tokens.dart';

/// Standard page: a scrollable column with responsive gutters and a max width. The title sits
/// at the top of that column, aligned with the content, so every page starts the same way.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions,
    this.maxWidth = 720,
    this.showBack = true,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final double maxWidth;

  /// False on a landing view that the router stacks on another page (the mode chooser),
  /// where Back would only lead sideways.
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final short = size.height < 900;
    final gutter = size.width >= 1600 ? Spacing.xxxl : Breakpoints.gutter(Breakpoints.of(context));
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            gutter,
            short ? Spacing.md : Spacing.xl,
            gutter,
            Spacing.xxl,
          ),
          children: [
            MaxWidth(
              maxWidth: maxWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PageHeader(title: title, actions: actions, showBack: showBack),
                  SizedBox(height: short ? Spacing.lg : Spacing.xl),
                  ...children,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The page title row: a back button when there is somewhere to go back to, the title in
/// the one page-title style, and the page's actions on the right.
class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.actions,
    this.below,
    this.showBack = true,
    this.dense = false,
  });

  final String title;
  final bool showBack;
  final List<Widget>? actions;

  /// A muted line under the title ("Updated 14:02").
  final String? below;

  /// A smaller title for working screens (Results), where the content, not the page
  /// name, should lead.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = Breakpoints.of(context).isCompact;
    // The brief's large light title, smaller on a phone so a word still fits the line.
    final titleStyle = dense
        ? theme.textTheme.headlineSmall?.copyWith(
            fontSize: compact ? 22 : 24,
            fontWeight: FontWeight.w500,
          )
        : compact || MediaQuery.sizeOf(context).height < 900
        ? theme.textTheme.headlineLarge?.copyWith(fontSize: compact ? 32 : 38)
        : theme.textTheme.headlineLarge;
    return LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          if (showBack && Navigator.of(context).canPop()) ...[
            const BackButton(),
            // A clear gap between the back key and the title block it sits beside.
            const SizedBox(width: Spacing.lg),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(header: true, child: Text(title, style: titleStyle)),
                if (below != null) ...[
                  const SizedBox(height: 2),
                  Text(below!, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          // Capped at half the row and wrapping, so a long action label never overflows on a
          // narrow phone, while the title keeps the rest of the row.
          if (actions case final actions? when actions.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth / 2),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Spacing.xs,
                children: actions,
              ),
            ),
        ],
      ),
    );
  }
}
