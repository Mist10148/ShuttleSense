import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/server_config.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/court_view.dart';
import 'notice.dart';
import 'tactile.dart';

export '../../data/models/court_view.dart';

/// The camera position last chosen, remembered on this device (most people film the same way).
class CourtViewController extends Notifier<CourtView> {
  static const _key = 'court_view';

  @override
  CourtView build() {
    try {
      final saved = ref.read(sharedPreferencesProvider).getString(_key);
      return CourtView.values.firstWhere((v) => v.name == saved, orElse: () => CourtView.end);
    } on Object {
      return CourtView.end; // no preferences (tests)
    }
  }

  void set(CourtView view) {
    state = view;
    try {
      ref.read(sharedPreferencesProvider).setString(_key, view.name);
    } on Object {
      // Not saved; still used for this session.
    }
  }
}

final courtViewProvider = NotifierProvider<CourtViewController, CourtView>(CourtViewController.new);

/// "Camera position": behind a baseline or from the side. It sets the corner order, and the
/// ends are called Near / Far or Left / Right to match the picture.
class CourtViewField extends ConsumerWidget {
  const CourtViewField({super.key, this.enabled = true, this.dense = false});

  final bool enabled;

  /// Just the two choices, for a tight column beside the picture (phone calibration).
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(courtViewProvider);
    final theme = Theme.of(context);
    final choice = DepthSegmented<CourtView>(
      segments: const [
        ButtonSegment(
          value: CourtView.end,
          icon: Icon(Icons.stay_current_portrait_rounded),
          label: Text('Behind court'),
        ),
        ButtonSegment(
          value: CourtView.side,
          icon: Icon(Icons.stay_current_landscape_rounded),
          label: Text('Side-on'),
        ),
      ],
      selected: {view},
      onSelectionChanged: enabled ? (s) => ref.read(courtViewProvider.notifier).set(s.first) : null,
    );
    if (dense) {
      return Semantics(label: 'Camera position', container: true, child: choice);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            Text('Camera position', style: theme.textTheme.labelLarge),
            choice,
          ],
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          view == CourtView.end
              ? 'Behind a baseline, the court running away from the camera. The ends are '
                    'called Near and Far.'
              : 'Beside the court, the net upright in the middle of the picture. The ends are '
                    'called Left and Right, as they appear in the video.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// How to film for good results. Tracking and stroke labels are only as good as the video.
class CameraTips extends StatelessWidget {
  const CameraTips({super.key});

  @override
  Widget build(BuildContext context) => const NoticeBanner(
    title: 'For the best results',
    icon: Icons.videocam_outlined,
    message:
        'Film from a raised, steady spot behind a baseline or level with the net at the '
        'side, with the whole court and both players in view, in even light. Low, shaky, '
        'zoomed-in or corner angles, and players hidden behind the net or each other, give '
        'weaker tracking and stroke labels.',
  );
}
