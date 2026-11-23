import 'package:flutter/material.dart';

/// App-wide scrolling: soft, eased ends (bouncing) on every platform instead of a hard stop.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: RangeMaintainingScrollPhysics());
}

/// A scroll controller whose mouse-wheel steps glide (about 220 ms, ease-out) instead of
/// jumping. Steps that arrive while a glide is running add to where it is heading, so fast
/// wheel turns stay smooth and still go the full distance.
class SmoothScrollController extends ScrollController {
  SmoothScrollController({super.initialScrollOffset, super.keepScrollOffset, super.debugLabel});

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SmoothWheelPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );
}

class _SmoothWheelPosition extends ScrollPositionWithSingleContext {
  _SmoothWheelPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
  });

  static const _glide = Duration(milliseconds: 160);

  double? _target;

  @override
  void pointerScroll(double delta) {
    if (delta == 0) return;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context.storageContext) ?? false;
    // Trackpads send many small steps that are already smooth: those scroll directly.
    if (reduce || delta.abs() < 40) return super.pointerScroll(delta);
    final gliding = _target != null && activity is DrivenScrollActivity;
    final from = gliding ? _target! : pixels;
    final to = (from + delta).clamp(minScrollExtent, maxScrollExtent);
    if (to == pixels) return;
    _target = to;
    animateTo(to, duration: _glide, curve: Curves.easeOutCubic);
  }
}

/// Owns a [SmoothScrollController] for a scroll view built by [builder].
class SmoothScroll extends StatefulWidget {
  const SmoothScroll({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller) builder;

  @override
  State<SmoothScroll> createState() => _SmoothScrollState();
}

class _SmoothScrollState extends State<SmoothScroll> {
  final _controller = SmoothScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _controller);
}
