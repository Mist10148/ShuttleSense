import 'package:flutter/material.dart';

/// Spacing steps used for padding and gaps.
abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Corner radii: small for chips and notices, medium for inputs, large for cards.
abstract final class Radii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
}

/// Smallest comfortable touch target for courtside controls.
const double kMinTouchTarget = 48;

/// Marks drawn on top of video frames. Video looks the same in light and dark mode, so these
/// stay fixed bright colours instead of following the theme.
abstract final class OverlayColors {
  static const Color corners = Colors.yellowAccent;
  static const Color cornerLabel = Colors.black;
  static const Color courtLines = Colors.lightBlueAccent;
  static const Color playerBox = Colors.cyanAccent;
  static const Color shuttle = Colors.yellowAccent;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

/// Black or white, whichever reads better on [background].
Color onColor(Color background) =>
    _contrast(background, Colors.white) >= _contrast(background, Colors.black)
    ? Colors.white
    : Colors.black;

/// Colours of a line call: in, out, and a call waiting for review. Text on them uses
/// [onColor], which keeps at least 4.5:1 for every colour here.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({required this.inCall, required this.outCall, required this.uncertain});

  final Color inCall;
  final Color outCall;
  final Color uncertain;

  static const light = StatusColors(
    inCall: Color(0xFF2E7D32),
    outCall: Color(0xFFC62828),
    uncertain: Color(0xFFFFB300),
  );

  static const dark = StatusColors(
    inCall: Color(0xFF81C784),
    outCall: Color(0xFFEF9A9A),
    uncertain: Color(0xFFFFD54F),
  );

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>() ?? light;

  /// The colour for a call: [review] wins over in or out.
  Color forCall({required bool isIn, bool review = false}) =>
      review ? uncertain : (isIn ? inCall : outCall);

  @override
  StatusColors copyWith({Color? inCall, Color? outCall, Color? uncertain}) => StatusColors(
    inCall: inCall ?? this.inCall,
    outCall: outCall ?? this.outCall,
    uncertain: uncertain ?? this.uncertain,
  );

  @override
  StatusColors lerp(StatusColors? other, double t) {
    if (other == null) return this;
    return StatusColors(
      inCall: Color.lerp(inCall, other.inCall, t)!,
      outCall: Color.lerp(outCall, other.outCall, t)!,
      uncertain: Color.lerp(uncertain, other.uncertain, t)!,
    );
  }
}
