import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_skin.dart';
import '../../../core/theme/skins/skin_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/skin/backrooms_wallpaper.dart';
import '../../../shared/widgets/skin/denia_pattern.dart';
import '../../../shared/widgets/tactile.dart';
import '../../skins/fx/skin_fx_host.dart';
import '../../skins/fx/skin_switch.dart';

/// Settings > Theme (docs/THEMES.md): Classic, Backrooms, Denia (Light) and Denia (Dark), each
/// a key with a small preview of its tones. Choosing one plays its switch animation.
class ThemePickerCard extends ConsumerWidget {
  const ThemePickerCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    // while a switch runs, show where it is going
    final AppSkin chosen = ref.watch(skinSwitchProvider)?.target ?? ref.watch(appSkinProvider);
    return SectionCard(
      title: 'Theme',
      icon: Icons.wallpaper_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Spacing.md,
            runSpacing: Spacing.md,
            children: [
              for (final skin in AppSkin.values)
                SizedBox(
                  width: 136,
                  child: KeyCap(
                    key: ValueKey('theme-${skin.name}'),
                    selected: skin == chosen,
                    semanticLabel: '${skin.label} theme',
                    padding: const EdgeInsets.all(Spacing.sm),
                    radius: Radii.md,
                    onTap: () => ref
                        .read(skinSwitchProvider.notifier)
                        .request(
                          skin,
                          reduceMotion: MediaQuery.disableAnimationsOf(context),
                          origin: SkinFxHost.recentTap(),
                          fromSettings: true,
                        ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SkinSwatch(skin: skin),
                        const SizedBox(height: Spacing.sm),
                        Text(
                          skin.label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          Text(
            'Light and Dark under Appearance apply to Classic and move Denia between its light '
            'and dark sides. Backrooms is light only.',
            style: muted,
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('theme-gallery'),
              onPressed: () => context.push(Routes.themeGallery),
              icon: const Icon(Icons.grid_view_outlined),
              label: const Text('Preview all themes'),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          _ThemeExtras(denia: chosen.family == SkinFamily.denia),
        ],
      ),
    );
  }
}

/// The switch animation and its sound, and, for Denia, the stickers and how strongly they show.
class _ThemeExtras extends ConsumerWidget {
  const _ThemeExtras({required this.denia});

  final bool denia;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fx = ref.watch(skinFxProvider);
    final n = ref.read(skinFxProvider.notifier);
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TactileSwitchTile(
          key: const ValueKey('theme-motion'),
          title: const Text('Switch animation'),
          subtitle: Text(
            reduced
                ? 'Off while your device asks for reduced motion'
                : 'Plays when you change to or from Backrooms or Denia',
          ),
          value: fx.motion,
          onChanged: n.setMotion,
        ),
        TactileSwitchTile(
          key: const ValueKey('theme-sound'),
          title: const Text('Switch sound'),
          subtitle: const Text('The hum of Backrooms, the chimes and bubbles of Denia'),
          value: fx.sound,
          onChanged: fx.motion ? n.setSound : null,
        ),
        if (denia) ...[
          TactileSwitchTile(
            key: const ValueKey('theme-stickers'),
            title: const Text('Stickers'),
            subtitle: const Text('Denia stickers scattered behind the pages'),
            value: fx.stickers,
            onChanged: n.setStickers,
          ),
          if (fx.stickers) ...[
            const SizedBox(height: Spacing.sm),
            DepthSegmented<StickerStrength>(
              key: const ValueKey('theme-sticker-strength'),
              segments: [
                for (final s in StickerStrength.values)
                  ButtonSegment(value: s, label: Text(s.label)),
              ],
              selected: {fx.stickerStrength},
              onSelectionChanged: (s) => n.setStickerStrength(s.first),
            ),
          ],
        ],
      ],
    );
  }
}

/// A small preview of [skin]: its page (with wallpaper or pattern), a raised plate, an accent
/// key and a line of text, in the theme's own tones.
class SkinSwatch extends StatelessWidget {
  const SkinSwatch({super.key, required this.skin, this.brightness});

  final AppSkin skin;

  /// Classic's half to show; follows the current theme when null.
  final Brightness? brightness;

  @override
  Widget build(BuildContext context) {
    final b = bundleFor(skin);
    final dark = (brightness ?? Theme.of(context).brightness) == Brightness.dark;
    final p = b?.palette ?? (dark ? AppPalette.dark : AppPalette.light);
    final t = b?.tactile ?? (dark ? TactileTokens.dark : TactileTokens.light);
    final pattern = switch (skin.family) {
      SkinFamily.backrooms => const BackroomsWallpaperPainter(),
      SkinFamily.denia => DeniaPatternPainter(dark: skin.isDark),
      SkinFamily.classic => null,
    };
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        child: SizedBox(
          height: 64,
          child: ColoredBox(
            color: p.page,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (pattern != null) CustomPaint(painter: pattern),
                Positioned(
                  left: 10,
                  top: 10,
                  right: 34,
                  bottom: 10,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [t.raisedTop, t.raisedBottom],
                      ),
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(color: t.shade, blurRadius: 6, offset: const Offset(3, 3)),
                        BoxShadow(color: t.highlight, blurRadius: 6, offset: const Offset(-2, -2)),
                      ],
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _Line(color: p.ink, width: 40),
                          const SizedBox(height: 5),
                          _Line(color: p.text3, width: 26),
                        ],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 10,
                  bottom: 10,
                  width: 16,
                  height: 16,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: t.primary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: t.shade, blurRadius: 4, offset: const Offset(2, 2)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: 4,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
  );
}
