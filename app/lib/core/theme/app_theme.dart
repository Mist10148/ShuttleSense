import 'package:flutter/material.dart';

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

  static ThemeData light() =>
      _build(Brightness.light, playerColorsLight, StatusColors.light, AppPalette.light);

  static ThemeData dark() =>
      _build(Brightness.dark, playerColorsDark, StatusColors.dark, AppPalette.dark);

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
    AppPalette p,
  ) {
    final scheme = _scheme(brightness, p, status);
    const pill = StadiumBorder();
    final control = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md));
    final cardEdge = p.hairline == null ? BorderSide.none : BorderSide(color: p.hairline!);
    // Buttons are pills: black primary, grey tonal secondary, outlined and text as ghosts.
    const button = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(64, kMinTouchTarget)),
      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Spacing.xl)),
      shape: WidgetStatePropertyAll(pill),
      textStyle: WidgetStatePropertyAll(
        TextStyle(fontFamily: fontFamily, fontSize: 14, fontWeight: FontWeight.w500),
      ),
    );
    final noBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      borderSide: BorderSide.none,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: fontFamily,
      extensions: [players, status, p],
      visualDensity: VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: p.canvas,
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
        elevation: 0,
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: cardEdge,
        ),
      ),
      filledButtonTheme: const FilledButtonThemeData(style: button),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: button.copyWith(
          side: WidgetStatePropertyAll(BorderSide(color: p.text3.withValues(alpha: 0.4))),
          foregroundColor: WidgetStatePropertyAll(p.ink),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: button.copyWith(
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Spacing.lg)),
          foregroundColor: WidgetStatePropertyAll(p.ink),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size.square(kMinTouchTarget)),
          shape: WidgetStatePropertyAll(control),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, kMinTouchTarget)),
          shape: const WidgetStatePropertyAll(pill),
          side: WidgetStatePropertyAll(BorderSide(color: p.surface2)),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? p.ink : p.surface2,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? p.onInk : p.ink,
          ),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.ink : p.surface2,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.onInk : p.text3,
        ),
        trackOutlineColor: WidgetStatePropertyAll(p.text3.withValues(alpha: 0.4)),
      ),
      chipTheme: ChipThemeData(
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
        backgroundColor: p.surface2,
        selectedColor: p.ink,
        checkmarkColor: p.onInk,
        disabledColor: p.surface2.withValues(alpha: 0.5),
        // The chip resolves a WidgetStateColor in its label style per state.
        labelStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 13,
          color: WidgetStateColor.resolveWith(
            (s) => s.contains(WidgetState.selected) ? p.onInk : p.ink,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.surface2,
        border: noBorder,
        enabledBorder: noBorder,
        focusedBorder: noBorder.copyWith(borderSide: BorderSide(color: p.ink, width: 2)),
      ),
      listTileTheme: ListTileThemeData(shape: control),
      dialogTheme: DialogThemeData(
        backgroundColor: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.lg)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.surface,
        surfaceTintColor: Colors.transparent,
        shape: control,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: p.ink, borderRadius: BorderRadius.circular(Radii.sm)),
        textStyle: TextStyle(fontFamily: fontFamily, fontSize: 12, color: p.onInk),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: p.ink,
        contentTextStyle: TextStyle(fontFamily: fontFamily, fontSize: 14, color: p.onInk),
        actionTextColor: p.onInk,
        shape: control,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.ink,
        linearTrackColor: p.surface2,
      ),
      dividerTheme: DividerThemeData(color: p.hairline ?? p.surface2),
    );
  }
}
