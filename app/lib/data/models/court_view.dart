import 'package:flutter/widgets.dart';

/// Where the camera stands: behind a baseline (the court runs away from the camera) or
/// beside the court (the court runs across the picture, the net upright in the middle).
enum CourtView { end, side }

/// The four corners to mark, in the order the server maps them to the court (near left,
/// near right, far right, far left). From the side, the left end of the picture is the
/// "near" end, so the same order reads back left, front left, front right, back right
/// (front is the sideline closest to the camera).
List<String> cornerNamesFor(CourtView view) => switch (view) {
  CourtView.end => const ['Near left', 'Near right', 'Far right', 'Far left'],
  CourtView.side => const ['Back left', 'Front left', 'Front right', 'Back right'],
};

/// The marking order as one phrase, for instructions.
String cornerOrderFor(CourtView view) =>
    cornerNamesFor(view).map((n) => n.toLowerCase()).join(', ');

/// What the two ends of the court are called on screen. The server always says near and
/// far; a side-on video shows them as left and right.
class SideNames {
  const SideNames._(this.near, this.far);

  static const ends = SideNames._('Near', 'Far');
  static const leftRight = SideNames._('Left', 'Right');
  static const rightLeft = SideNames._('Right', 'Left');

  /// Names for a chosen camera position, before any corners are marked.
  factory SideNames.forView(CourtView view) => view == CourtView.side ? leftRight : ends;

  /// Names read from the marked corners (near left, near right, far right, far left in image
  /// pixels): when the near and far baselines sit beside each other in the picture rather
  /// than one above the other, the video is side-on.
  factory SideNames.fromCorners(List<({double x, double y})>? corners) {
    if (corners == null || corners.length != 4) return ends;
    final nx = (corners[0].x + corners[1].x) / 2, ny = (corners[0].y + corners[1].y) / 2;
    final fx = (corners[2].x + corners[3].x) / 2, fy = (corners[2].y + corners[3].y) / 2;
    if ((fx - nx).abs() <= (fy - ny).abs()) return ends;
    return nx < fx ? leftRight : rightLeft;
  }

  final String near;
  final String far;

  bool get sideOn => near != 'Near';

  /// near, near_1 ... -> Near / Left; far_2 -> Far 2 / Right 2.
  String side(String who) => who.startsWith('near') ? near : far;

  String player(String who) {
    final name = side(who);
    return who.endsWith('_1') || who.endsWith('_2')
        ? '$name ${who.substring(who.length - 1)}'
        : name;
  }

  @override
  bool operator ==(Object other) => other is SideNames && other.near == near && other.far == far;

  @override
  int get hashCode => Object.hash(near, far);
}

/// Gives the widgets below the side names of the session they show (Results, Live).
class CourtSides extends InheritedWidget {
  const CourtSides({super.key, required this.names, required super.child});

  final SideNames names;

  static SideNames of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CourtSides>()?.names ?? SideNames.ends;

  @override
  bool updateShouldNotify(CourtSides old) => old.names != names;
}

extension CourtSidesContext on BuildContext {
  /// The on-screen name of a side or player slot (near_1 -> Near 1, or Left 1 side-on).
  String sideLabel(String who) => CourtSides.of(this).player(who);
}
