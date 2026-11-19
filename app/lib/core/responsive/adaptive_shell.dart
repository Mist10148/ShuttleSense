import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/offline_banner.dart';
import '../../shared/widgets/surfaces.dart';
import '../../shared/widgets/top_bar.dart';
import '../theme/theme_mode.dart';
import '../theme/tokens.dart';
import 'breakpoints.dart';

class ShellDestination {
  const ShellDestination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const shellDestinations = [
  ShellDestination('Analyze', Icons.insights_outlined, Icons.insights),
  ShellDestination('History', Icons.history_outlined, Icons.history),
  ShellDestination('Settings', Icons.settings_outlined, Icons.settings),
];

/// Phones: top bar, page, bottom tab bar. Tablets and laptops: one floating glass shell over
/// the pastel canvas, holding the icon rail, the top bar and the page.
class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _select(int index) =>
      navigationShell.goBranch(index, initialLocation: index == navigationShell.currentIndex);

  @override
  Widget build(BuildContext context) {
    final windowClass = Breakpoints.of(context);
    if (windowClass.isCompact) {
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const TopBar(compact: true),
              Expanded(child: OfflineBanner(child: navigationShell)),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: _select,
          destinations: [
            for (final d in shellDestinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      );
    }

    final margin = windowClass == WindowClass.expanded ? Spacing.xl : Spacing.lg;
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(margin),
            child: GlassPanel(
              child: Row(
                children: [
                  IconRail(selectedIndex: navigationShell.currentIndex, onSelect: _select),
                  Expanded(
                    child: Column(
                      children: [
                        const TopBar(compact: false),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(0, 0, Spacing.md, Spacing.md),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(Radii.lg),
                              child: OfflineBanner(child: navigationShell),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The slim column of rounded-square buttons on the left of the shell: brand, one button per
/// destination (the active one filled with ink), and the light/dark switch at the bottom.
class IconRail extends ConsumerWidget {
  const IconRail({super.key, required this.selectedIndex, required this.onSelect});

  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: 80,
      child: Column(
        children: [
          const SizedBox(height: Spacing.lg),
          Tooltip(
            message: 'ShuttleSense',
            child: IconChip(
              icon: Icons.sports_tennis,
              size: 44,
              background: AppPalette.of(context).lavender,
            ),
          ),
          const SizedBox(height: Spacing.xl),
          for (final (i, d) in shellDestinations.indexed) ...[
            _RailButton(
              label: d.label,
              icon: i == selectedIndex ? d.selectedIcon : d.icon,
              selected: i == selectedIndex,
              onTap: () => onSelect(i),
            ),
            const SizedBox(height: Spacing.sm),
          ],
          const Spacer(),
          _RailButton(
            label: dark ? 'Switch to light theme' : 'Switch to dark theme',
            icon: dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            selected: false,
            onTap: () =>
                ref.read(themeModeProvider.notifier).set(dark ? ThemeMode.light : ThemeMode.dark),
          ),
          const SizedBox(height: Spacing.lg),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final shape = BorderRadius.circular(Radii.md);
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        excludeSemantics: true,
        child: Material(
          color: selected ? p.ink : Colors.transparent,
          borderRadius: shape,
          child: InkWell(
            borderRadius: shape,
            onTap: onTap,
            child: SizedBox.square(
              dimension: kMinTouchTarget,
              child: Icon(icon, color: selected ? p.onInk : p.text2),
            ),
          ),
        ),
      ),
    );
  }
}
