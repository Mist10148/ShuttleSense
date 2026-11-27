import 'package:flutter/material.dart';

import '../../../ui/depth.dart';
import '../app_skin.dart';
import '../tokens.dart';
import 'skin_bundle.dart';
import 'skin_decor.dart';

/// Backrooms: the yellowed office wallpaper and damp plaster under humming fluorescent light
/// (Wonderboard style.css: --bg #B6B461, --card #D4D291, --bd #8C8A46, --tx #24230D,
/// --mu #403E14, --ac #5A5712). The tactile tones are moulded from the same plaster: a pale
/// paper-yellow highlight and an olive-brown shade. Text is darker than Wonderboard's muted
/// tone so it keeps 4.5:1 on every surface, the wallpaper included (docs/THEMES.md).
abstract final class BackroomsTokens {
  static const wall = Color(0xFFB6B461);
  static const card = Color(0xFFD4D291);
  static const border = Color(0xFF8C8A46);
  static const text = Color(0xFF24230D);
  static const muted = Color(0xFF403E14);
  static const accent = Color(0xFF5A5712);

  static const palette = AppPalette(
    ink: text,
    onInk: Color(0xFFFFFDE6),
    text2: Color(0xFF33310F),
    text3: Color(0xFF3A3812),
    surface: card,
    surface2: Color(0xFFC9C77F),
    hairline: null,
    lavender: Color(0xFFD5CBA4),
    sky: Color(0xFFC5CF9E),
    mint: Color(0xFFC9D596),
    pink: Color(0xFFDBC59A),
    peach: Color(0xFFDFCB88),
    brand: Color(0xFF2F5E14),
    info: Color(0xFF2C5574),
    chart: [
      Color(0xFF2C5574),
      Color(0xFF6B4E8A),
      Color(0xFF9A3B2E),
      Color(0xFF2F5E14),
      Color(0xFF8A5A00),
    ],
    progress: [border, accent],
    canvas: wall,
    // the fluorescent tubes: a pale warm light pooled near the top of the page
    canvasGlows: [Color(0x66FFFCCE), Color(0x33FFFCCE), Color(0x1F26240B)],
    page: wall,
    shell: wall,
    cardShadow: [
      BoxShadow(color: Color(0x4D5E5B22), blurRadius: 26, offset: Offset(10, 12)),
      BoxShadow(color: Color(0x99F4F1C0), blurRadius: 22, offset: Offset(-8, -8)),
    ],
    popoverShadow: [
      BoxShadow(color: Color(0x7324230D), blurRadius: 40, spreadRadius: -18, offset: Offset(0, 18)),
    ],
  );

  static const tactile = TactileTokens(
    chassisTop: wall,
    chassisBottom: wall,
    raisedTop: Color(0xFFDEDC9F),
    raisedBottom: Color(0xFFCFCD8A),
    recess: Color(0xFFC2C076),
    screenTop: Color(0xFFD9D79A),
    screenBottom: Color(0xFFCBC985),
    highlight: Color(0xCCF4F1C0),
    shade: Color(0xB35E5B22),
    innerShade: Color(0xD95E5B22),
    innerLight: Color(0xB3F4F1C0),
    rim: Color(0x80F4F1C0),
    engraved: Color(0xFF33310F),
    engravedShadow: Color(0xFFEAE7B0),
    keyEdge: 0.14,
    capSheen: 0.3,
    primary: accent,
    primaryDeep: Color(0xFF45430C),
    onPrimary: Color(0xFFFFFDE6),
  );

  static const depth = DepthTheme(
    page: wall,
    bg: Color(0xFFCFCD8A),
    well: Color(0xFFC2C076),
    shade: Color(0xFF2E2C08),
    hi: Color(0xFFFFFBD0),
    accent: accent,
    good: Color(0xFF2F5E14),
    warn: Color(0xFF6E4A00),
    bad: Color(0xFF8E2A12),
    ink: text,
    muted: Color(0xFF33310F),
  );

  static const analysis = AnalysisColors(
    accent: Color(0xFFDCE65A),
    onAccent: Color(0xFF1E1E0A),
    accentInk: Color(0xFF36400A),
    track: Color(0xFFC2C076),
  );

  static const decor = SkinDecor(skin: AppSkin.backrooms, focus: accent);

  static const bundle = SkinBundle(
    brightness: Brightness.light,
    palette: palette,
    tactile: tactile,
    depth: depth,
    analysis: analysis,
    decor: decor,
  );
}
