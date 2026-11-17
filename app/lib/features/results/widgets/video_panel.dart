import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../data/models/clip_record.dart';
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
    this.overlay,
  });

  /// Only needed when [available]: there is no player to make for a missing video.
  final VideoController? controller;

  /// Null while the job is still loading, so "not available" is not claimed too early.
  final bool? available;
  final double? aspectRatio;

  /// Drawn over the playing video, the same size (the hit bursts).
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio ?? 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: Colors.black,
          child: switch (available) {
            true when controller != null => Semantics(
              label: 'Annotated rally video',
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(controller: controller!),
                  ?overlay,
                ],
              ),
            ),
            true => const Center(child: CircularProgressIndicator()),
            false => const MessageView(
              icon: Icons.videocam_off_outlined,
              message: 'Annotated video not available',
              detail: 'The render stage did not produce a video for this job.',
            ),
            null => const Center(child: CircularProgressIndicator()),
          },
        ),
      ),
    );
  }
}

/// The few player operations the controls need (a seam for widget tests).
abstract interface class PlaybackTarget {
  Duration get position;
  bool get playing;

  /// Emits whenever playback starts or stops.
  Stream<bool> get playingChanges;
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
  Stream<bool> get playingChanges => player.stream.playing;
  @override
  Future<void> playOrPause() => player.playOrPause();
  @override
  Future<void> seek(Duration position) => player.seek(position);
  @override
  Future<void> setRate(double rate) => player.setRate(rate);
}

/// Step one video frame forward (+1) or back (-1), pausing first. Works on frame indices and
/// seeks to the middle of the frame, so repeated steps never drift onto the previous frame
/// through position rounding.
Future<void> stepFrame(PlaybackTarget target, double fps, int direction) async {
  if (target.playing) await target.playOrPause();
  final next = frameIndexAt(target.position, fps) + direction;
  await target.seek(next <= 0 ? Duration.zero : frameMid(next, fps));
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
        StreamBuilder<bool>(
          stream: widget.target.playingChanges,
          initialData: widget.target.playing,
          builder: (context, snapshot) {
            final playing = snapshot.data ?? false;
            return IconButton(
              tooltip: playing ? 'Pause (Space)' : 'Play (Space)',
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: widget.target.playOrPause,
            );
          },
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
/// and right arrows step one frame. Only while no control inside has focus: a focused
/// button, chip or list keeps Space and the arrows for itself.
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
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (!node.hasPrimaryFocus || event is KeyUpEvent) return KeyEventResult.ignored;
        final action = switch (event.logicalKey) {
          LogicalKeyboardKey.space when event is KeyDownEvent => target.playOrPause,
          LogicalKeyboardKey.arrowLeft => () => stepFrame(target, fps, -1),
          LogicalKeyboardKey.arrowRight => () => stepFrame(target, fps, 1),
          _ => null,
        };
        if (action == null) return KeyEventResult.ignored;
        action();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}

/// Loads [url] with optional auth headers into [player], paused.
Future<void> openVideo(Player player, String url, Map<String, String> headers) =>
    player.open(Media(url, httpHeaders: headers), play: false);
