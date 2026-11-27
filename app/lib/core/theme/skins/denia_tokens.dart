import 'package:flutter/material.dart';

import '../../../ui/depth.dart';
import '../app_skin.dart';
import '../tokens.dart';
import 'skin_bundle.dart';
import 'skin_decor.dart';

/// Denia (Light): her pink "Stagecraft" side (Wonderboard denia.css: --bg #F9E8EF,
/// --side #FDF3F7, --card #FFFFFF, --bd #E9BFD0, --tx #2A1A24, --mu #86576D, --ac #C2255C,
/// her gem's blue #3B82C4 for focus and a little gold #B8862F). Plates are lit pearl-white
/// with a dusty-rose shade, so the moulded look survives on pink (docs/THEMES.md).
abstract final class DeniaLightTokens {
  static const page = Color(0xFFF9E8EF);
  static const side = Color(0xFFFDF3F7);
  static const border = Color(0xFFE9BFD0);
  static const text = Color(0xFF2A1A24);
  static const accent = Color(0xFFC2255C);
  static const gem = Color(0xFF3B82C4);
  static const gold = Color(0xFFB8862F);

  static const palette = AppPalette(
    ink: text,
    onInk: Color(0xFFFFFFFF),
    text2: Color(0xFF5A3648),
    text3: Color(0xFF744A5E),
    surface: Color(0xFFFFF7FA),
    surface2: Color(0xFFFBE9F0),
    hairline: null,
    lavender: Color(0xFFEADFFB),
    sky: Color(0xFFDCEBF8),
    mint: Color(0xFFDDF3E8),
    pink: Color(0xFFFADCE7),
    peach: Color(0xFFFCE6D6),
    brand: Color(0xFF1D7A50),
    info: Color(0xFF2F6FA8),
    chart: [gem, Color(0xFF9A6BD8), accent, Color(0xFF2E9E6B), gold],
    progress: [Color(0xFFE58FB6), accent],
    canvas: page,
    // the stage light: white from above, a pink edge, a pale blue floor
    canvasGlows: [Color(0xCCFFFFFF), Color(0x3DE28CB6), Color(0x33B8DDF3)],
    page: page,
    shell: side,
    cardShadow: [
      BoxShadow(color: Color(0x26A0506E), blurRadius: 26, offset: Offset(10, 12)),
      BoxShadow(color: Color(0xCCFFFFFF), blurRadius: 22, offset: Offset(-8, -8)),
    ],
    popoverShadow: [
      BoxShadow(color: Color(0x592A1A24), blurRadius: 40, spreadRadius: -18, offset: Offset(0, 18)),
    ],
  );

  static const tactile = TactileTokens(
    chassisTop: page,
    chassisBottom: page,
    raisedTop: Color(0xFFFFFFFF),
    raisedBottom: Color(0xFFFDF1F5),
    recess: Color(0xFFF3DEE7),
    screenTop: Color(0xFFFFF8FB),
    screenBottom: Color(0xFFF7E6EE),
    highlight: Color(0xE6FFFFFF),
    shade: Color(0xB3D3A3B8),
    innerShade: Color(0xD9D3A3B8),
    innerLight: Color(0xB3FFFFFF),
    rim: Color(0x99FFFFFF),
    engraved: Color(0xFF744A5E),
    engravedShadow: Color(0xFFFFFFFF),
    keyEdge: 0.12,
    capSheen: 0.35,
    primary: accent,
    primaryDeep: Color(0xFF9E1A49),
    onPrimary: Color(0xFFFFFFFF),
  );

  static const depth = DepthTheme(
    page: page,
    bg: Color(0xFFFDF1F5),
    well: Color(0xFFF3DEE7),
    shade: Color(0xFF6E2A4A),
    hi: Color(0xFFFFFFFF),
    accent: accent,
    good: Color(0xFF1D7A50),
    warn: Color(0xFF8A5205),
    bad: Color(0xFFA82C2C),
    ink: text,
    muted: Color(0xFF744A5E),
  );

  static const analysis = AnalysisColors(
    accent: Color(0xFFF7A8CB),
    onAccent: text,
    accentInk: Color(0xFFA31E4E),
    track: Color(0xFFF3DEE7),
  );

  static const decor = SkinDecor(
    skin: AppSkin.deniaLight,
    lace: border,
    gold: gold,
    focus: gem,
    pillFill: Color(0xEBFFFFFF),
    pillRim: Color(0xFFE58FB6),
    pillText: Color(0xFF8A3559),
  );

  static const bundle = SkinBundle(
    brightness: Brightness.light,
    palette: palette,
    tactile: tactile,
    depth: depth,
    analysis: analysis,
    decor: decor,
  );
}
