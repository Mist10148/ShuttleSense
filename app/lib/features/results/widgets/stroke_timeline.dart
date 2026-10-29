import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/message_view.dart';

/// C3 / FR-C3: one row per hit; tapping a row seeks the video.
class StrokeTimeline extends StatelessWidget {
  const StrokeTimeline({super.key, required this.hits, this.currentHitId, required this.onSeek});

  final List<Hit> hits;
  final int? currentHitId;
  final ValueChanged<Hit> onSeek;

  @override
  Widget build(BuildContext context) {
    if (hits.isEmpty) {
      return const MessageView(
        icon: Icons.timeline,
        message: 'No hits detected yet',
        detail: 'Hits and strokes appear here once those pipeline stages are in place.',
      );
    }
    final colors = PlayerColors.of(context);
    return ListView.separated(
      itemCount: hits.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final hit = hits[i];
        final stroke = kStrokeLabels[hit.stroke] ?? 'Unclassified';
        final details = [
          if (hit.confidence != null) '${(hit.confidence! * 100).round()}%',
          if (hit.speedKmh != null) '~${hit.speedKmh!.round()} km/h (est.)',
          ?hit.tip,
        ].join(' · ');
        return ListTile(
          selected: hit.id == currentHitId,
          onTap: () => onSeek(hit),
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: colors.forSide(hit.player),
            child: Text(
              hit.player == 'near' ? 'N' : 'F',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          title: Text(stroke),
          subtitle: details.isEmpty ? null : Text(details),
          trailing: Text(_time(hit.timeS)),
        );
      },
    );
  }

  static String _time(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toStringAsFixed(1).padLeft(4, '0');
    return '$m:$s';
  }
}
