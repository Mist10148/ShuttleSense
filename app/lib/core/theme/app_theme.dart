import 'package:flutter/material.dart';

import '../../shared/widgets/tactile.dart';
import '../../ui/depth.dart';
import 'tokens.dart';

export 'tokens.dart';

/// Colors used for the players everywhere (skeletons, minimap, timeline). In doubles the
/// partners ([near2], [far2]) are a second colour of their side's family (Phase 9).
@immutable
class PlayerColors extends ThemeExtension<PlayerColors> {
  const PlayerColors({
    required this.near,
    required this.far,
    required this.shuttle,
    required this.near2,
    required this.far2,
  });

  final Color near;
  final Color far;
  final Color shuttle;
  final Color near2;
  final Color far2;

  static PlayerColors of(BuildContext context) =>
      Theme.of(context).extension<PlayerColors>() ?? AppTheme.playerColorsLight;

  Color forSide(String side) => side == 'near' ? near : far;

  /// A side (near, far) or a doubles slot (near_1 ... far_2).
  Color forPlayer(String player) => switch (player) {
    'near_2' => near2,
    'far_2' => far2,
    _ => forSide(player.startsWith('near') ? 'near' : 'far'),
  };

  @override
  PlayerColors copyWith({Color? near, Color? far, Color? shuttle, Color? near2, Color? far2}) =>
      PlayerColors(
        near: near ?? this.near,
        far: far ?? this.far,
        shuttle: shuttle ?? this.shuttle,
        near2: near2 ?? this.near2,
        far2: far2 ?? this.far2,
      );

  @override
  PlayerColors lerp(PlayerColors? other, double t) {
    if (other == null) return this;
    return PlayerColors(
      near: Color.lerp(near, other.near, t)!,
      far: Color.lerp(far, other.far, t)!,
      shuttle: Color.lerp(shuttle, other.shuttle, t)!,
      near2: Color.lerp(near2, other.near2, t)!,
      far2: Color.lerp(far2, other.far2, t)!,
    );
  }
}

abstract final class AppTheme {
  /// Court green.
  static const Color seed = Color(0xFF2E7D4F);

  static const playerColorsLight = PlayerColors(
    near: Color(0xFF1565C0),
    far: Color(0xFFD84315), // 3:1 against the light court surface (T4.11)
    shuttle: Color(0xFFC6A700),
    near2: Color(0xFF3949AB), // doubles partners: indigo and brown, also 3:1
    far2: Color(0xFF8D6E63),
  );

  static const playerColorsDark = PlayerColors(
    near: Color(0xFF64B5F6),
    far: Color(0xFFFFB74D),
    shuttle: Color(0xFFFFEE58),
    near2: Color(0xFF9FA8DA),
    far2: Color(0xFFBCAAA4),
  );

  /// The bundled font (assets/fonts, SIL Open Font License).
  static const String fontFamily = 'Outfit';

  /// [highContrast]: the system asked for more contrast, so depth becomes plain borders.
  static ThemeData light({bool highContrast = false}) => _build(
    Brightness.light,
    playerColorsLight,
    StatusColors.light,
    AppPalette.light,
    highContrast: highContrast,
  );

  static ThemeData dark({bool highContrast = false}) => _build(
    Brightness.dark,
    playerColorsDark,
    StatusColors.dark,
    AppPalette.dark,
    highContrast: highContrast,
  );

  /// The brief's type scale: light display figures, regular headings, 14 body, 11 captions.
  static TextTheme _textTheme(AppPalette p) {
    // Scores, clocks and stats: digits of equal width, so numbers do not shift as they change.
    const figures = TextStyle(
      fontWeight: FontWeight.w300,
      fontFeatures: [FontFeature.tabularFigures()],
      height: 1.1,
    );
    return TextTheme(
      displayLarge: figures.copyWith(fontSize: 48),
      displayMedium: figures.copyWith(fontSize: 36),
      displaySmall: figures.copyWith(fontSize: 28),
      headlineLarge: const TextStyle(fontSize: 48, fontWeight: FontWeight.w300, height: 1.1),
      headlineMedium: const TextStyle(fontSize: 28, fontWeight: FontWeight.w400),
      headlineSmall: const TextStyle(fontSize: 22, fontWeight: FontWeight.w400),
      titleLarge: const TextStyle(fontSize: 18, fontWeight: FontWeight.w400),
      titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      titleSmall: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      bodyLarge: const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
      bodyMedium: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
      bodySmall: TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: p.text2),
      labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      labelMedium: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w400, color: p.text3),
    );
  }

  static ColorScheme _scheme(Brightness brightness, AppPalette p, StatusColors status) =>
      ColorScheme.fromSeed(seedColor: seed, brightness: brightness).copyWith(
        primary: p.ink,
        onPrimary: p.onInk,
        primaryContainer: p.lavender,
        onPrimaryContainer: p.ink,
        secondary: p.brand,
        secondaryContainer: p.surface2,
        onSecondaryContainer: p.ink,
        tertiary: p.info,
        tertiaryContainer: p.sky,
        onTertiaryContainer: p.ink,
        error: status.outCall,
        errorContainer: p.pink,
        onErrorContainer: p.ink,
        surface: p.surface,
        onSurface: p.ink,
        onSurfaceVariant: p.text2,
        surfaceContainerLowest: p.surface,
        surfaceContainerLow: p.surface,
        surfaceContainer: p.surface2,
        surfaceContainerHigh: p.surface2,
        surfaceContainerHighest: p.surface2,
        outline: p.text3,
        outlineVariant: p.hairline ?? p.surface2,
        inverseSurface: p.ink,
        onInverseSurface: p.onInk,
        surfaceTint: Colors.transparent,
      );

  static ThemeData _build(
    Brightness brightness,
    PlayerColors players,
    StatusColors status,
    AppPalette p, {
    bool highContrast = false,
  }) {
    final scheme = _scheme(brightness, p, status);
    final base = brightness == Brightness.dark ? TactileTokens.dark : TactileTokens.light;
    final t = highContrast ? base.asFlat(p.ink.withValues(alpha: 0.6)) : base;
    // Depth level 3, floating: menus, dialogs, sheets and toasts. Opaque, largest shadow.
    final floatShadow = highContrast ? Colors.transparent : t.shade;
    final floatShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: highContrast ? t.rim : t.rim.withValues(alpha: 0.6)),
    );
    final control = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md));
    // Every button is tactile (shared/widgets/tactile.dart): raised at rest, lifted on hover,
    // sunk while pressed. Padding stays Material's, which shrinks at large text sizes.
    const label = WidgetStatePropertyAll(
      TextStyle(fontFamily: fontFamily, fontSize: 14, fontWeight: FontWeight.w600),
    );
    const size = WidgetStatePropertyAll(Size(64, kMinTouchTarget));
    Color disabledInk(Color c) => c.withValues(alpha: 0.45);
    WidgetStateProperty<Color> ink(Color c) => WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? disabledInk(c) : c,
    );
    final noBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      borderSide: BorderSide.none,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: fontFamily,
      extensions: [
        players,
        status,
        p,
        brightness == Brightness.dark ? AnalysisColors.dark : AnalysisColors.light,
        t,
        brightness == Brightness.dark ? DepthTheme.dark : DepthTheme.light,
      ],
      visualDensity: VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: p.page,
      textTheme: _textTheme(p),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          color: p.ink,
          fontSize: 22,
          fontWeight: FontWeight.w400,
        ),
      ),
      // White cards on the canvas, no hard border (a 6% hairline in dark mode).
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 2,
        shadowColor: t.shade,
        color: t.raisedBottom,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: t.rim),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: tactileButtonStyle(
          TactileButtonKind.primary,
        ).copyWith(minimumSize: size, textStyle: label, foregroundColor: ink(t.onPrimary)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: tactileButtonStyle(
          TactileButtonKind.secondary,
        ).copyWith(minimumSize: size, textStyle: label, foregroundColor: ink(p.ink)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: tactileButtonStyle(TactileButtonKind.ghost).copyWith(
          minimumSize: size,
          textStyle: label,
          foregroundColor: ink(brightness == Brightness.dark ? p.info : t.primaryDeep),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: tactileButtonStyle(TactileButtonKind.secondary).copyWith(
          minimumSize: const WidgetStatePropertyAll(Size.square(kMinTouchTarget - 4)),
          foregroundColor: ink(p.text2),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: tactileSegmentStyle().copyWith(
          minimumSize: const WidgetStatePropertyAll(Size(48, kMinTouchTarget)),
          textStyle: label,
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? p.ink : p.text3,
          ),
          iconColor: WidgetStatePropertyAll(t.primary),
          // The segmented button does not pass a background builder down to its segments,
          // so the tray and the raised chosen segment are drawn with plain state colours.
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? t.raisedTop : t.recess,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: t.shade.withValues(alpha: 0.35))),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.primary : t.recess,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.onPrimary : t.raisedTop,
        ),
        trackOutlineColor: WidgetStatePropertyAll(buttonEdgeColor(brightness, p, t)),
      ),
      // Chips are options pressed into the surface; the chosen one pops up as a blue key.
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: t.recess,
        elevation: 2,
        pressElevation: 0,
        shadowColor: Colors.transparent,
        selectedShadowColor: t.primary.withValues(alpha: 0.6),
        selectedColor: t.primary,
        checkmarkColor: t.onPrimary,
        disabledColor: p.surface2.withValues(alpha: 0.5),
        // The chip resolves a WidgetStateColor in its label style per state.
        labelStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 13,
          color: WidgetStateColor.resolveWith(
            (s) => s.contains(WidgetState.selected) ? t.onPrimary : p.ink,
          ),
        ),
      ),
      // Checkboxes and radios sit in small wells and light up blue when chosen.
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        side: WidgetStateBorderSide.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? BorderSide(color: t.primaryDeep)
              : BorderSide(color: t.shade, width: 1.5),
        ),
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.primary : t.recess,
        ),
        checkColor: WidgetStatePropertyAll(t.onPrimary),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.primary : p.text3,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.recess,
        border: noBorder,
        enabledBorder: noBorder,
        focusedBorder: noBorder.copyWith(borderSide: BorderSide(color: t.primary, width: 2)),
      ),
      listTileTheme: ListTileThemeData(shape: control),
      // An expanded section is pushed in: it sinks into a well while open.
      expansionTileTheme: ExpansionTileThemeData(
        backgroundColor: t.recess,
        collapsedBackgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: highContrast ? t.rim : t.primary.withValues(alpha: 0.35)),
        ),
        collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        iconColor: t.primary,
        textColor: p.ink,
        expansionAnimationStyle: const AnimationStyle(
          duration: Duration(milliseconds: 180),
          curve: Curves.easeOut,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.raisedTop,
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shadowColor: floatShadow,
        shape: floatShape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.raisedTop,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: floatShadow,
        shape: floatShape,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(t.raisedTop),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(12),
          shadowColor: WidgetStatePropertyAll(floatShadow),
          shape: WidgetStatePropertyAll(floatShape),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.raisedTop,
        surfaceTintColor: Colors.transparent,
        elevation: 16,
        shadowColor: floatShadow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 350),
        decoration: BoxDecoration(
          color: p.ink,
          borderRadius: BorderRadius.circular(Radii.sm),
          boxShadow: highContrast
              ? null
              : [BoxShadow(color: t.shade, blurRadius: 12, offset: const Offset(0, 5))],
        ),
        textStyle: TextStyle(fontFamily: fontFamily, fontSize: 12, color: p.onInk),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.ink,
        elevation: 10,
        contentTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 14, color: p.onInk),
        actionTextColor: p.onInk,
        shape: control,
      ),
      // Phones: the bottom tab bar, with the active tab as an ink pill.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.chassisBottom,
        elevation: 3,
        shadowColor: t.shade,
        surfaceTintColor: Colors.transparent,
        indicatorColor: t.primary,
        indicatorShape: const StadiumBorder(),
        iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? t.onPrimary : p.text2),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontFamily: fontFamily,
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
            color: s.contains(WidgetState.selected) ? p.ink : p.text2,
          ),
        ),
      ),
      // Top tabs: pills, the active one filled with ink.
      tabBarTheme: TabBarThemeData(
        indicator: BoxDecoration(
          gradient: raisedGradient(t),
          borderRadius: BorderRadius.circular(Radii.pill),
          boxShadow: chipShadows(t),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerHeight: 0,
        labelColor: p.ink,
        unselectedLabelColor: p.text3,
        splashBorderRadius: BorderRadius.circular(Radii.pill),
        labelStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: const TextStyle(fontFamily: fontFamily, fontSize: 14),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.ink,
        linearTrackColor: p.surface2,
      ),
      dividerTheme: DividerThemeData(color: p.hairline ?? p.surface2),
    );
  }
}

/// The thin edge of neutral controls such as the switch track.
Color buttonEdgeColor(Brightness b, AppPalette p, TactileTokens t) =>
    b == Brightness.dark ? t.rim : p.ink.withValues(alpha: 0.13);
