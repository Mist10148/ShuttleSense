import 'package:flutter/material.dart';

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
