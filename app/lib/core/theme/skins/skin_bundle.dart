import 'package:flutter/material.dart';

import '../../../ui/depth.dart';
import '../app_theme.dart';
import 'skin_decor.dart';

/// Every token one theme needs, so the tactile builder draws it with the same recipe as
/// Classic and only the tones change. Line-call and player colours follow the brightness.
@immutable
class SkinBundle {
  const SkinBundle({
    required this.brightness,
    required this.palette,
    required this.tactile,
    required this.depth,
    required this.analysis,
    required this.decor,
  });

  final Brightness brightness;
  final AppPalette palette;
  final TactileTokens tactile;
  final DepthTheme depth;
  final AnalysisColors analysis;
  final SkinDecor decor;

  bool get isDark => brightness == Brightness.dark;

  /// In, out and uncertain keep their Classic colours (PRD design principles, D27, D49).
  StatusColors get status => isDark ? StatusColors.dark : StatusColors.light;

  PlayerColors get players => isDark ? AppTheme.playerColorsDark : AppTheme.playerColorsLight;
}
