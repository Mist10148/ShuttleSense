import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../shared/widgets/message_view.dart';

/// Playback speeds offered for reviewing strokes.
const kPlaybackRates = [0.25, 0.5, 1.0];

/// Plays the annotated MP4 streamed from the backend (F7, C3). media_kit's own controls
/// give play/pause, seeking and fullscreen; [PlaybackControls] adds speed and frame steps.
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
              ? Semantics(
                  label: 'Annotated rally video',
                  child: Video(controller: controller),
                )
              : const MessageView(
                  icon: Icons.videocam_off_outlined,
                  message: 'Annotated video not available',
                  detail: 'The render stage did not produce a video for this job.',
                ),
        ),
      ),
    );
  }
}

/// The few player operations the controls need (a seam for widget tests).
abstract interface class PlaybackTarget {
  Duration get position;
  bool get playing;
  Future<void> playOrPause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);
}

class MediaKitTarget implements PlaybackTarget {
  MediaKitTarget(this.player);

  final Player player;

  @override
  Duration get position => player.state.position;
  @override
  bool get playing => player.state.playing;
  @override
  Future<void> playOrPause() => player.playOrPause();
  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> setRate(double rate) => player.setRate(rate);
}

/// Step one video frame forward (+1) or back (-1), pausing first.
Future<void> stepFrame(PlaybackTarget target, double fps, int direction) async {
  if (target.playing) await target.playOrPause();
  final frame = Duration(microseconds: (Duration.microsecondsPerSecond / fps).round());
  final next = target.position + frame * direction;
  await target.seek(next.isNegative ? Duration.zero : next);
}

/// Speed and frame-step buttons under the video (T4.6).
class PlaybackControls extends StatefulWidget {
  const PlaybackControls({super.key, required this.target, required this.fps});

  final PlaybackTarget target;
  final double fps;

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  double _rate = 1;

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    await widget.target.setRate(rate);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        IconButton(
          tooltip: 'Previous frame (Left arrow)',
          icon: const Icon(Icons.skip_previous),
          onPressed: () => stepFrame(widget.target, widget.fps, -1),
        ),
        IconButton(
          tooltip: 'Play or pause (Space)',
          icon: const Icon(Icons.play_arrow),
          onPressed: widget.target.playOrPause,
        ),
        IconButton(
          tooltip: 'Next frame (Right arrow)',
          icon: const Icon(Icons.skip_next),
          onPressed: () => stepFrame(widget.target, widget.fps, 1),
        ),
        SegmentedButton<double>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: [
            for (final r in kPlaybackRates)
              ButtonSegment(value: r, label: Text('${r == 1 ? '1' : r}×'), tooltip: '$r× speed'),
          ],
          selected: {_rate},
          onSelectionChanged: (s) => _setRate(s.first),
        ),
      ],
    );
  }
}

/// Keyboard control for the whole results screen (T4.11): Space plays or pauses, the left
/// and right arrows step one frame.
class PlaybackShortcuts extends StatelessWidget {
  const PlaybackShortcuts({
    super.key,
    required this.target,
    required this.fps,
    required this.child,
  });

  final PlaybackTarget target;
  final double fps;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): target.playOrPause,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => stepFrame(target, fps, -1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => stepFrame(target, fps, 1),
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

/// Creates a player for [url] with optional auth headers.
Player openPlayer(String url, Map<String, String> headers) {
  final player = Player();
  player.open(Media(url, httpHeaders: headers), play: false);
  return player;
}
