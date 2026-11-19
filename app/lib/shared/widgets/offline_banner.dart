import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../core/theme/tokens.dart';
import 'surfaces.dart';

/// Shows a pink glass strip above [child] while the saved server does not answer GET /health
/// (T4.9), with Retry.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(healthProvider);
    final error = health.error;
    final offline = error is ApiException && error.unreachable;
    final p = AppPalette.of(context);
    return Column(
      children: [
        if (offline)
          Padding(
            padding: const EdgeInsets.fromLTRB(Spacing.md, Spacing.sm, Spacing.md, 0),
            child: GlassPanel(
              radius: Radii.md,
              tint: p.pink.withValues(alpha: 0.85),
              padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.xs, Spacing.xs, Spacing.xs),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Icon(Icons.cloud_off, color: p.ink, size: 20),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Text(
                        'Server unreachable. Check the Wi-Fi or the tunnel.',
                        style: TextStyle(color: p.ink),
                      ),
                    ),
                    TextButton(
                      onPressed: () => ref.invalidate(healthProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Expanded(child: child),
      ],
    );
  }
}
