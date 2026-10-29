import 'package:flutter/material.dart';

/// Colors used for the two players everywhere (skeletons, minimap, timeline).
@immutable
class PlayerColors extends ThemeExtension<PlayerColors> {
  const PlayerColors({required this.near, required this.far, required this.shuttle});

  final Color near;
  final Color far;
  final Color shuttle;

  static PlayerColors of(BuildContext context) =>
      Theme.of(context).extension<PlayerColors>() ?? AppTheme.playerColorsLight;

  Color forSide(String side) => side == 'near' ? near : far;

  @override
  PlayerColors copyWith({Color? near, Color? far, Color? shuttle}) =>
      PlayerColors(near: near ?? this.near, far: far ?? this.far, shuttle: shuttle ?? this.shuttle);

  @override
  PlayerColors lerp(PlayerColors? other, double t) {
    if (other == null) return this;
    return PlayerColors(
      near: Color.lerp(near, other.near, t)!,
      far: Color.lerp(far, other.far, t)!,
      shuttle: Color.lerp(shuttle, other.shuttle, t)!,
    );
  }
}

abstract final class AppTheme {
  /// Court green.
  static const Color seed = Color(0xFF2E7D4F);

  static const playerColorsLight = PlayerColors(
    near: Color(0xFF1565C0),
    far: Color(0xFFE65100),
    shuttle: Color(0xFFC6A700),
  );

  static const playerColorsDark = PlayerColors(
    near: Color(0xFF64B5F6),
    far: Color(0xFFFFB74D),
    shuttle: Color(0xFFFFEE58),
  );

  static ThemeData light() => _build(Brightness.light, playerColorsLight);

  static ThemeData dark() => _build(Brightness.dark, playerColorsDark);

  static ThemeData _build(Brightness brightness, PlayerColors players) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      extensions: [players],
      visualDensity: VisualDensity.adaptivePlatformDensity,
      cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
    );
  }
}
