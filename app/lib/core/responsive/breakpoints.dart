import 'package:flutter/widgets.dart';

/// Material 3 window size classes used across the app (docs/ARCHITECTURE.md §4).
enum WindowClass {
  /// < 600 dp: phones in portrait.
  compact,

  /// 600–1023 dp: tablets, phones in landscape, narrow desktop windows.
  medium,

  /// >= 1024 dp: laptops, desktops, large tablets in landscape.
  expanded;

  bool get isCompact => this == WindowClass.compact;
}

abstract final class Breakpoints {
  static const double medium = 600;
  static const double expanded = 1024;

  static WindowClass forWidth(double width) {
    if (width < medium) return WindowClass.compact;
    if (width < expanded) return WindowClass.medium;
    return WindowClass.expanded;
  }

  static WindowClass of(BuildContext context) => forWidth(MediaQuery.sizeOf(context).width);

  /// Horizontal page padding for each class.
  static double gutter(WindowClass c) => switch (c) {
    WindowClass.compact => 16,
    WindowClass.medium => 24,
    WindowClass.expanded => 32,
  };
}

/// Centers [child] and caps its width so forms do not stretch across a laptop screen.
class MaxWidth extends StatelessWidget {
  const MaxWidth({super.key, this.maxWidth = 720, required this.child});

  final double maxWidth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
