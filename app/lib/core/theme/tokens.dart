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
    required this.page,
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

  /// The solid page behind screens inside the shell: the glass tone, made opaque so pages
  /// do not show through each other while a route transition runs.
  final Color page;

  /// The translucent fill of the floating app shell.
  final Color shell;
  final List<BoxShadow> cardShadow;
  final List<BoxShadow> popoverShadow;

  /// The five pastels in a fixed order, for cycling through categories.
  List<Color> get pastels => [lavender, sky, mint, pink, peach];

  static const _series = [
    Color(0xFF4F86C6),
    Color(0xFF8C7AE6),
    Color(0xFFE0779B),
    Color(0xFF2E9E6B),
    Color(0xFFE0911E),
  ];

  static const light = AppPalette(
    ink: Color(0xFF112D4E),
    onInk: Color(0xFFFFFFFF),
    text2: Color(0xFF34465F),
    text3: Color(0xFF4A5D78),
    surface: Color(0xFFEEF1F6),
    surface2: Color(0xFFE1E6EE),
    hairline: null,
    lavender: Color(0xFFE3DEFB),
    sky: Color(0xFFD6E6F8),
    mint: Color(0xFFD9F1E4),
    pink: Color(0xFFF9DCE5),
    peach: Color(0xFFFBE7D2),
    brand: Color(0xFF1D7A50),
    info: Color(0xFF3F72AF),
    chart: _series,
    progress: [Color(0xFF5A8BC6), Color(0xFF2E9E6B)],
    canvas: Color(0xFFCDD5E2),
    canvasGlows: [Color(0xFFC9D8F0), Color(0xFFE6DAF2), Color(0xFFD3EDE3)],
    page: Color(0xFFCDD5E2),
    shell: Color(0xFFCDD5E2),
    cardShadow: [
      BoxShadow(color: Color(0x1F112D4E), blurRadius: 26, offset: Offset(10, 12)),
      BoxShadow(color: Color(0xBFFFFFFF), blurRadius: 22, offset: Offset(-8, -8)),
    ],
    popoverShadow: [
      BoxShadow(color: Color(0x73112D4E), blurRadius: 40, spreadRadius: -18, offset: Offset(0, 18)),
    ],
  );

  static const dark = AppPalette(
    ink: Color(0xFFECEDEF),
    onInk: Color(0xFF11161D),
    text2: Color(0xFFC2C5CB),
    text3: Color(0xFF9EA2AA),
    surface: Color(0xFF2A2C31),
    surface2: Color(0xFF32353B),
    hairline: null,
    lavender: Color(0xFF2C2A4A),
    sky: Color(0xFF1C3048),
    mint: Color(0xFF1A3A2C),
    pink: Color(0xFF42242F),
    peach: Color(0xFF43301C),
    brand: Color(0xFF5CC896),
    info: Color(0xFF8CB0E0),
    chart: _series,
    progress: [Color(0xFF5A8BC6), Color(0xFF2E9E6B)],
    canvas: Color(0xFF1F2125),
    canvasGlows: [Color(0x403F72AF), Color(0x2E8C7AE6), Color(0x262E9E6B)],
    page: Color(0xFF1F2125),
    shell: Color(0xFF1F2125),
    cardShadow: [
      BoxShadow(color: Color(0x99000000), blurRadius: 26, offset: Offset(10, 12)),
      BoxShadow(color: Color(0x0DFFFFFF), blurRadius: 18, offset: Offset(-6, -6)),
    ],
    popoverShadow: [
      BoxShadow(color: Color(0xB3000000), blurRadius: 40, spreadRadius: -18, offset: Offset(0, 18)),
    ],
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

  /// Fills of the numbered corner markers 1-4 (lavender, sky, mint, peach), ringed in white.
  static const List<Color> cornerMarkers = [
    Color(0xFFDCD8FC),
    Color(0xFFCFE5FB),
    Color(0xFFDDF5D3),
    Color(0xFFFDE6CF),
  ];
  static const Color cornerLabel = Colors.black;
  static const Color courtLines = Colors.lightBlueAccent;
  static const Color playerBox = Colors.cyanAccent;
  static const Color shuttle = Colors.yellowAccent;
}

/// The results screen's accent: lime marks only what is happening now (the current shot,
/// its mark on the bar, its timeline row). Follows the app's light or dark theme.
@immutable
class AnalysisColors extends ThemeExtension<AnalysisColors> {
  const AnalysisColors({
    required this.accent,
    required this.onAccent,
    required this.accentInk,
    required this.track,
  });

  /// Lime fill (the shot block, the current row's tint).
  final Color accent;
  final Color onAccent;

  /// The accent as text or a small mark on the page: dark olive on light, lime on dark.
  final Color accentInk;

  /// Empty part of bars and tracks.
  final Color track;

  static const light = AnalysisColors(
    accent: Color(0xFFC6F24E),
    onAccent: Color(0xFF1E1E1E),
    accentInk: Color(0xFF4F6B00),
    track: Color(0xFFE6E6EC),
  );

  static const dark = AnalysisColors(
    accent: Color(0xFFC6F24E),
    onAccent: Color(0xFF151817),
    accentInk: Color(0xFFC6F24E),
    track: Color(0xFF30363A),
  );

  static AnalysisColors of(BuildContext context) =>
      Theme.of(context).extension<AnalysisColors>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  AnalysisColors copyWith() => this;

  @override
  AnalysisColors lerp(AnalysisColors? other, double t) => other == null || t < 0.5 ? this : other;
}

/// Big figures on the analysis screens (speed, shot number, score): condensed and tabular.
const TextStyle kFigureStyle = TextStyle(
  fontWeight: FontWeight.w600,
  fontFeatures: [FontFeature.tabularFigures()],
  height: 0.95,
  letterSpacing: -0.5,
);

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

/// The tactile layer: a moulded chassis lit from the top left, raised plates and keys you
/// press, and sunken wells and screens that hold data. Light and dark keep the same recipe;
/// only the tones change. Read with [TactileTokens.of].
@immutable
class TactileTokens extends ThemeExtension<TactileTokens> {
  const TactileTokens({
    required this.chassisTop,
    required this.chassisBottom,
    required this.raisedTop,
    required this.raisedBottom,
    required this.recess,
    required this.screenTop,
    required this.screenBottom,
    required this.highlight,
    required this.shade,
    required this.innerShade,
    required this.innerLight,
    required this.rim,
    required this.engraved,
    required this.engravedShadow,
    required this.keyEdge,
    required this.capSheen,
    required this.primary,
    required this.primaryDeep,
    required this.onPrimary,
    this.flat = false,
  });

  /// The app body: a soft vertical gradient.
  final Color chassisTop;
  final Color chassisBottom;

  /// Cards, plates and neutral keys.
  final Color raisedTop;
  final Color raisedBottom;

  /// Wells, tracks and input slots.
  final Color recess;

  /// The inset display that holds the court and other drawings.
  final Color screenTop;
  final Color screenBottom;

  /// Outer light (top left) and outer shadow (bottom right) of raised parts.
  final Color highlight;
  final Color shade;

  /// Inner shadow and inner lip light of sunken parts.
  final Color innerShade;
  final Color innerLight;

  /// The 1 px edge around raised parts.
  final Color rim;

  /// Small labels pressed into the surface, and the 1 px light or dark line that sells it.
  final Color engraved;
  final Color engravedShadow;

  /// How far a key's visible base is darkened from its cap colour (0 to 1).
  final double keyEdge;

  /// How much lighter the top of a raised part is than its base colour (0 to 1).
  final double capSheen;

  /// High-contrast mode: depth collapses to plain borders (no shadows, highlights or sheen).
  final bool flat;

  /// The same tones with the depth collapsed to plain [border] lines, for high contrast.
  TactileTokens asFlat(Color border) => TactileTokens(
    chassisTop: chassisTop,
    chassisBottom: chassisBottom,
    raisedTop: raisedBottom,
    raisedBottom: raisedBottom,
    recess: recess,
    screenTop: screenTop,
    screenBottom: screenTop,
    highlight: Colors.transparent,
    shade: Colors.transparent,
    innerShade: Colors.transparent,
    innerLight: Colors.transparent,
    rim: border,
    engraved: engraved,
    engravedShadow: Colors.transparent,
    keyEdge: 0,
    capSheen: 0,
    primary: primary,
    primaryDeep: primary,
    onPrimary: onPrimary,
    flat: true,
  );

  /// The main action: a steel-blue key with white text.
  final Color primary;
  final Color primaryDeep;
  final Color onPrimary;

  /// The base edge colour under a key of [cap] colour.
  Color edgeFor(Color cap) => Color.lerp(cap, Colors.black, keyEdge)!;

  static const light = TactileTokens(
    chassisTop: Color(0xFFCDD5E2),
    chassisBottom: Color(0xFFCDD5E2),
    raisedTop: Color(0xFFFFFFFF),
    raisedBottom: Color(0xFFEEF2F8),
    recess: Color(0xFFDDE3EC),
    screenTop: Color(0xFFF4F7FB),
    screenBottom: Color(0xFFE6ECF4),
    highlight: Color(0xCCFFFFFF),
    shade: Color(0xB38D9CB4),
    innerShade: Color(0xD98D9CB4),
    innerLight: Color(0xB3FFFFFF),
    rim: Color(0x80FFFFFF),
    engraved: Color(0xFF4A5D78),
    engravedShadow: Color(0xFFFFFFFF),
    keyEdge: 0.12,
    capSheen: 0.35,
    primary: Color(0xFF3F72AF),
    primaryDeep: Color(0xFF2C5A93),
    onPrimary: Color(0xFFFFFFFF),
  );

  static const dark = TactileTokens(
    chassisTop: Color(0xFF1F2125),
    chassisBottom: Color(0xFF1F2125),
    raisedTop: Color(0xFF2D3035),
    raisedBottom: Color(0xFF26282D),
    recess: Color(0xFF1A1C1F),
    screenTop: Color(0xFF191B1E),
    screenBottom: Color(0xFF1C1E22),
    highlight: Color(0xFF292C31),
    shade: Color(0xCC111214),
    innerShade: Color(0xE60F1012),
    innerLight: Color(0x14FFFFFF),
    rim: Color(0x0FFFFFFF),
    engraved: Color(0xFF9EA2AA),
    engravedShadow: Color(0x99000000),
    keyEdge: 0.35,
    capSheen: 0.06,
    primary: Color(0xFF3F72AF),
    primaryDeep: Color(0xFF2C5A93),
    onPrimary: Color(0xFFFFFFFF),
  );

  static TactileTokens of(BuildContext context) =>
      Theme.of(context).extension<TactileTokens>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  TactileTokens copyWith() => this;

  @override
  TactileTokens lerp(TactileTokens? other, double t) => other == null || t < 0.5 ? this : other;
}
