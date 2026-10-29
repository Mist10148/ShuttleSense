import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../shared/widgets/message_view.dart';

/// Plays the annotated MP4 streamed from the backend (F7, C3).
class VideoPanel extends StatelessWidget {
  const VideoPanel({
    super.key,
    required this.controller,
    required this.available,
    this.aspectRatio,
  });

  final VideoController controller;
  final bool available;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio ?? 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: Colors.black,
          child: available
              ? Video(controller: controller)
              : const MessageView(
                  icon: Icons.videocam_off_outlined,
                  message: 'Annotated video not available yet',
                  detail: 'The render stage produces it (T2.6, T2.7).',
                ),
        ),
      ),
    );
  }
}

/// Creates a player for [url] with optional auth headers.
Player openPlayer(String url, Map<String, String> headers) {
  final player = Player();
  player.open(Media(url, httpHeaders: headers), play: false);
  return player;
}
