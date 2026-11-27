import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_skin.dart';
import 'core/theme/skins/skin_theme.dart';
import 'core/theme/theme_mode.dart';
import 'features/skins/fx/skin_fx_host.dart';
import 'shared/widgets/skin/skin_scope.dart';
import 'shared/widgets/smooth_scroll.dart';

class ShuttleSenseApp extends ConsumerWidget {
  const ShuttleSenseApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Classic follows the Appearance mode; the other themes carry their own (docs/THEMES.md).
    final skin = ref.watch(appSkinProvider);
    final themes = themesFor(skin);
    return MaterialApp.router(
      title: 'ShuttleSense',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      theme: themes.light,
      darkTheme: themes.dark,
      highContrastTheme: themes.lightHc,
      highContrastDarkTheme: themes.darkHc,
      themeMode: skin.themeMode(ref.watch(themeModeProvider)),
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) => SkinFxHost(child: SkinScope(child: child!)),
    );
  }
}
