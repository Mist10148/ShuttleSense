/// Timeline of the switch into Backrooms (Wonderboard backroomsPlan.ts), in ms from the start:
/// a click and a black cover at 0, the theme changes behind it, the logo appears, then a
/// second click and the hum as the cover lifts and the logo fades.
abstract final class BackroomsPlan {
  /// The theme changes behind the cover.
  static const int applyAt = 150;

  /// Two seconds later the logo appears at once.
  static const int logoAt = applyAt + 2000;

  /// Two more seconds: a second click, the hum starts and the cover lifts.
  static const int revealAt = logoAt + 2000;

  /// The logo fades out over this long.
  static const int logoFadeMs = 5000;

  static const int endAt = revealAt + logoFadeMs;

  /// From Settings, the animation waits this long so the choice is seen to land first.
  static const int afterSettingsMs = 1000;

  /// The hum's volume at [tMs] into a clip [durMs] long: [start], fading linearly to silence.
  static double humVolume(double tMs, double durMs, {double start = 0.6}) =>
      durMs > 0 ? (1 - tMs / durMs).clamp(0.0, 1.0) * start : 0;

  /// The hum's length when the clip does not report one.
  static const int humFallbackMs = 20000;
}
