import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/offline_banner.dart';
import '../../shared/widgets/surfaces.dart';
import '../../shared/widgets/tactile.dart';
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

/// In the order of the router's shell branches.
const shellDestinations = [
  ShellDestination('Home', Icons.home_outlined, Icons.home),
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

    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          // The chassis fills the window edge to edge: no frame of canvas around it.
          child: Padding(
            padding: EdgeInsets.zero,
            child: GlassPanel(
              radius: 0,
              child: Row(
                children: [
                  IconRail(selectedIndex: navigationShell.currentIndex, onSelect: _select),
                  Expanded(
                    child: Column(
                      children: [
                        const TopBar(compact: false),
                        // Pages show the chassis through, so the rail's and top bar's shadows
                        // fall on one continuous surface instead of stopping at a page edge.
                        Expanded(
                          child: Theme(
                            data: Theme.of(
                              context,
                            ).copyWith(scaffoldBackgroundColor: Colors.transparent),
                            child: OfflineBanner(child: navigationShell),
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
    // The rail is a raised glass strip of keys standing on the chassis.
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.md, 0, Spacing.md),
      child: Raised(
        radius: 20,
        color: null,
        child: SizedBox(
          width: 68,
          child: Column(
            children: [
              const SizedBox(height: Spacing.md),
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
                onTap: () => ref
                    .read(themeModeProvider.notifier)
                    .set(dark ? ThemeMode.light : ThemeMode.dark),
              ),
              const SizedBox(height: Spacing.md),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailButton extends StatefulWidget {
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
  State<_RailButton> createState() => _RailButtonState();
}

class _RailButtonState extends State<_RailButton> {
  bool _hovered = false;
  bool _down = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final t = TactileTokens.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final selected = widget.selected;
    final states = {if (_hovered) WidgetState.hovered, if (_down) WidgetState.pressed};
    // The active destination is a lit blue key; the others are quiet until hovered.
    final decoration = BoxDecoration(
      gradient: selected
          ? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color.lerp(t.primary, Colors.white, 0.12)!, t.primary, t.primaryDeep],
            )
          : (_hovered ? raisedGradient(t) : null),
      borderRadius: BorderRadius.circular(13),
      border: _focused
          ? Border.all(color: t.primary, width: 2)
          : Border.all(color: selected || _hovered ? t.rim : Colors.transparent),
      boxShadow: selected
          ? [
              BoxShadow(
                color: t.primary.withValues(alpha: 0.35),
                blurRadius: 10,
                offset: const Offset(2, 4),
              ),
            ]
          : (_hovered ? chipShadows(t) : null),
    );
    return Tooltip(
      message: widget.label,
      child: Semantics(
        button: true,
        selected: selected,
        label: widget.label,
        excludeSemantics: true,
        child: AnimatedContainer(
          duration: still ? Duration.zero : Duration(milliseconds: _down ? 60 : 180),
          curve: const Cubic(0.2, 0.8, 0.2, 1),
          transform: buttonMotion(states, still: still),
          transformAlignment: Alignment.center,
          decoration: decoration,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(13),
              splashFactory: NoSplash.splashFactory,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              focusColor: Colors.transparent,
              onHover: (v) => setState(() => _hovered = v),
              onHighlightChanged: (v) => setState(() => _down = v),
              onFocusChange: (v) => setState(() => _focused = v),
              // The active destination is a raised blue key; the others sit in small wells.
              child: SizedBox.square(
                dimension: kMinTouchTarget,
                child: selected || _hovered
                    ? Icon(widget.icon, color: selected ? t.onPrimary : p.ink)
                    : Center(
                        child: Recess(
                          radius: 11,
                          padding: EdgeInsets.zero,
                          depth: 2.5,
                          child: SizedBox.square(
                            dimension: 38,
                            child: Icon(widget.icon, color: p.text2),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
