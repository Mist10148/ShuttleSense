import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/repositories/analysis_repository.dart';

/// Shows a strip above [child] while the saved server does not answer GET /health (T4.9).
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(healthProvider);
    final error = health.error;
    final offline = error is ApiException && error.unreachable;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (offline)
          Material(
            color: scheme.errorContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.cloud_off, color: scheme.onErrorContainer, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Server unreachable. Check the Wi-Fi or the tunnel.',
                        style: TextStyle(color: scheme.onErrorContainer),
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
