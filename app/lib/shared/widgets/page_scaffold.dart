import 'package:flutter/material.dart';

import '../../core/responsive/breakpoints.dart';
import '../../core/theme/tokens.dart';
import 'smooth_scroll.dart';
import 'top_bar.dart';

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
        child: SmoothScroll(
          builder: (context, controller) => ListView(
            controller: controller,
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
    final row = LayoutBuilder(
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
    final bar = TopBarReserve.maybeOf(context);
    return bar == null ? row : _ClearOfTopBar(bar: bar, child: row);
  }
}

/// Pads the header's right side so it ends where the floating top bar begins, when the two
/// share a line. Measured after layout: the header only knows where it sits once laid out.
class _ClearOfTopBar extends StatefulWidget {
  const _ClearOfTopBar({required this.bar, required this.child});

  final Size bar;
  final Widget child;

  @override
  State<_ClearOfTopBar> createState() => _ClearOfTopBarState();
}

class _ClearOfTopBarState extends State<_ClearOfTopBar> {
  double _inset = 0;

  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context).width;
    final barLeft = screen - widget.bar.width;
    // Only while the header is on the bar's line (not scrolled away under it).
    final onLine = topLeft.dy < widget.bar.height + 8;
    final right = topLeft.dx + box.size.width;
    final inset = onLine ? (right - barLeft + Spacing.md).clamp(0.0, box.size.width / 2) : _inset;
    if ((inset - _inset).abs() > 0.5) setState(() => _inset = inset);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    return Padding(
      padding: EdgeInsets.only(right: _inset),
      child: widget.child,
    );
  }
}
