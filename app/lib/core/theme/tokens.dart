import 'package:flutter/material.dart';

/// Spacing steps used for padding and gaps.
abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Corner radii: chips, inputs and buttons, cards, the app shell, and full pills.
abstract final class Radii {
  static const double sm = 8;
  static const double md = 14;
  static const double lg = 22;
  static const double xl = 28;
  static const double pill = 999;
}

/// Durations for hover, press and reveal animations. Callers skip them when
/// MediaQuery.disableAnimationsOf is true (reduced motion).
abstract final class Motion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Curve curve = Curves.easeOut;
}

/// Smallest comfortable touch target for courtside controls.
const double kMinTouchTarget = 48;

/// The redesign's colour tokens, light and dark. Screens read colours from here (or from the
/// ColorScheme built on it in app_theme.dart), never as hex literals.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.ink,
    required this.onInk,
    required this.text2,
    required this.text3,
    required this.surface,
    required this.surface2,
    required this.hairline,
    required this.lavender,
    required this.sky,
    required this.mint,
    required this.pink,
    required this.peach,
    required this.brand,
    required this.info,
    required this.chart,
    required this.progress,
    required this.canvas,
    required this.canvasGlows,
    required this.shell,
    required this.cardShadow,
    required this.popoverShadow,
  });

  /// Active nav, primary buttons, icon chips. In dark mode it flips to near-white.
  final Color ink;
  final Color onInk;

  /// Secondary and smallest text, darker than the brief's #6B6B6B and #8A8A8A: #8A8A8A is
  /// only 3.5:1 on white. These keep 4.5:1 on both surfaces, with text2 the stronger.
  final Color text2;
  final Color text3;
  final Color surface;
  final Color surface2;

  /// The 1px card edge (dark mode only; light cards rely on their shadow).
  final Color? hairline;

  final Color lavender;
  final Color sky;
  final Color mint;
  final Color pink;
  final Color peach;

  /// ShuttleSense green: success, online, in-calls.
  final Color brand;
  final Color info;

  /// Chart series in order: blue, violet, pink, mint, peach.
  final List<Color> chart;

  /// The gradient on progress bars, start to end.
  final List<Color> progress;

  /// The page background: a base colour with soft glows drawn over it.
  final Color canvas;
  final List<Color> canvasGlows;

  /// The translucent fill of the floating app shell.
  final Color shell;
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> popoverShadow;

  /// The five pastels in a fixed order, for cycling through categories.
  List<Color> get pastels => [lavender, sky, mint, pink, peach];

  static const _series = [
    Color(0xFF7DB3F0),
    Color(0xFF9C8CF2),
    Color(0xFFF2A7BE),
    Color(0xFF8FD9B6),
    Color(0xFFF5B98A),
  ];

  static const light = AppPalette(
    ink: Color(0xFF1E1E1E),
    onInk: Color(0xFFFFFFFF),
    text2: Color(0xFF5A5A5A),
    text3: Color(0xFF6A6A6A),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF4F4F6),
    hairline: null,
    lavender: Color(0xFFDCD8FC),
    sky: Color(0xFFCFE5FB),
    mint: Color(0xFFDDF5D3),
    pink: Color(0xFFFADBE5),
    peach: Color(0xFFFDE6CF),
    brand: Color(0xFF2F8F5B),
    info: Color(0xFF5B8DEF),
    chart: _series,
    progress: [Color(0xFF7DB3F0), Color(0xFF8FD9B6)],
    canvas: Color(0xFFEDEBF8),
    canvasGlows: [Color(0xFFC9C6F5), Color(0xFFF6D5D0), Color(0xFFD4F1E4)],
    shell: Color(0xB3FFFFFF),
    cardShadow: [BoxShadow(color: Color(0x0F1E1E3C), blurRadius: 24, offset: Offset(0, 8))],
    popoverShadow: [BoxShadow(color: Color(0x241E1E3C), blurRadius: 40, offset: Offset(0, 16))],
  );

  static const dark = AppPalette(
    ink: Color(0xFFECEFED),
    onInk: Color(0xFF151817),
    text2: Color(0xFFA3A9A6),
    text3: Color(0xFF959C99),
    surface: Color(0xFF1A1D1C),
    surface2: Color(0xFF252A28),
    hairline: Color(0x0FFFFFFF),
    lavender: Color(0xFF2E2B4D),
    sky: Color(0xFF1F3347),
    mint: Color(0xFF1F3A2B),
    pink: Color(0xFF432631),
    peach: Color(0xFF45321F),
    brand: Color(0xFF5CC48A),
    info: Color(0xFF8AAEF5),
    chart: _series,
    progress: [Color(0xFF7DB3F0), Color(0xFF8FD9B6)],
    canvas: Color(0xFF0F1211),
    canvasGlows: [Color(0x332F8F5B), Color(0x2E6E5BD9), Color(0x1A2F8F5B)],
    shell: Color(0xB3141716),
    cardShadow: [BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 8))],
    popoverShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 40, offset: Offset(0, 16))],
  );

  static AppPalette of(BuildContext context) => Theme.of(context).extension<AppPalette>() ?? light;

  @override
  AppPalette copyWith() => this;

  // shortcut: a theme change snaps halfway instead of blending each token; blend them if the
  // switch ever animates visibly.
  @override
  AppPalette lerp(AppPalette? other, double t) => other == null || t < 0.5 ? this : other;
}

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
    inCall: Color(0xFF2F8F5B),
    outCall: Color(0xFFD9534F),
    uncertain: Color(0xFFE7A93B),
  );

  static const dark = StatusColors(
    inCall: Color(0xFF5CC48A),
    outCall: Color(0xFFF08A86),
    uncertain: Color(0xFFF2C26B),
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
