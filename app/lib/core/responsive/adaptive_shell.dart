import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/offline_banner.dart';
import 'breakpoints.dart';
import '../theme/tokens.dart';

class ShellDestination {
  const ShellDestination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const shellDestinations = [
  ShellDestination('Analyze', Icons.sports_tennis_outlined, Icons.sports_tennis),
  ShellDestination('History', Icons.history_outlined, Icons.history),
  ShellDestination('Settings', Icons.settings_outlined, Icons.settings),
];

/// Bottom navigation on phones, a navigation rail on tablets and laptops.
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
        body: OfflineBanner(child: navigationShell),
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

    final extended = windowClass == WindowClass.expanded;
    return Scaffold(
      body: Row(
        children: [
          SafeArea(
            child: NavigationRail(
              extended: extended,
              labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _select,
              leading: Padding(
                padding: const EdgeInsets.symmetric(vertical: Spacing.md),
                child: extended
                    ? Text('ShuttleSense', style: Theme.of(context).textTheme.titleLarge)
                    : const Icon(Icons.sports_tennis),
              ),
              destinations: [
                for (final d in shellDestinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: OfflineBanner(child: navigationShell)),
        ],
      ),
    );
  }
}
