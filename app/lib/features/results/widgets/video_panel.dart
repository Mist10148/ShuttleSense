import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../data/models/clip_record.dart';
import '../../../shared/widgets/message_view.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/theme/app_theme.dart';

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
                  // The player's own controls sit on the footage: plain white icons, not the
                  // app's raised keys, which would read as glowing squares over the video.
                  Theme(
                    data: Theme.of(context).copyWith(
                      iconButtonTheme: IconButtonThemeData(
                        style: IconButton.styleFrom(foregroundColor: Colors.white),
                      ),
                    ),
                    child: Video(controller: controller!),
                  ),
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

/// The transport under the video (T4.6): previous shot, frame back, play, frame forward,
/// next shot, then [clock]; [extras] and the speed menu sit at the right end. Flat icons on
/// the bar instead of raised keys, so the row stays quiet; only Play is a small blue key.
class PlaybackControls extends StatefulWidget {
  const PlaybackControls({
    super.key,
    required this.target,
    required this.fps,
    this.onPreviousShot,
    this.onNextShot,
    this.clock,
    this.extras = const [],
  });

  final PlaybackTarget target;
  final double fps;

  /// Jump to the stroke before / after the playback position (J / L); hidden when null.
  final VoidCallback? onPreviousShot;
  final VoidCallback? onNextShot;

  /// The time readout, right after the transport.
  final Widget? clock;

  /// Toggles shown before the speed menu (the player rings).
  final List<Widget> extras;

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  double _rate = 1;

  Future<void> _setRate(double rate) async {
    setState(() => _rate = rate);
    await widget.target.setRate(rate);
  }

  static String _rateLabel(double r) => '${r == 1 ? '1' : r}×';

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final t = TactileTokens.of(context);
    final flat = IconButton.styleFrom(
      foregroundColor: p.text2,
      iconSize: 22,
      minimumSize: const Size.square(kMinTouchTarget),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
    final transport = <Widget>[
      if (widget.onPreviousShot != null)
        IconButton(
          style: flat,
          tooltip: 'Previous shot (J)',
          icon: const Icon(Icons.skip_previous_rounded),
          onPressed: widget.onPreviousShot,
        ),
      IconButton(
        style: flat,
        tooltip: 'Previous frame (Left arrow)',
        icon: const Icon(Icons.chevron_left_rounded),
        onPressed: () => stepFrame(widget.target, widget.fps, -1),
      ),
      StreamBuilder<bool>(
        stream: widget.target.playingChanges,
        initialData: widget.target.playing,
        builder: (context, snapshot) {
          final playing = snapshot.data ?? false;
          return IconButton(
            style: IconButton.styleFrom(
              backgroundColor: t.primary,
              foregroundColor: t.onPrimary,
              hoverColor: t.primaryDeep,
              iconSize: 22,
              // A 40 dp blue disc inside a full 48 dp tap target.
              minimumSize: const Size.square(kMinTouchTarget),
              padding: const EdgeInsets.all(4),
              shape: const CircleBorder(side: BorderSide(color: Colors.transparent, width: 4)),
              elevation: 1.5,
              shadowColor: t.primary.withValues(alpha: 0.5),
            ),
            tooltip: playing ? 'Pause (Space)' : 'Play (Space)',
            icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            onPressed: widget.target.playOrPause,
          );
        },
      ),
      IconButton(
        style: flat,
        tooltip: 'Next frame (Right arrow)',
        icon: const Icon(Icons.chevron_right_rounded),
        onPressed: () => stepFrame(widget.target, widget.fps, 1),
      ),
      if (widget.onNextShot != null)
        IconButton(
          style: flat,
          tooltip: 'Next shot (L)',
          icon: const Icon(Icons.skip_next_rounded),
          onPressed: widget.onNextShot,
        ),
    ];
    final speed = PopupMenuButton<double>(
      tooltip: 'Playback speed',
      initialValue: _rate,
      onSelected: _setRate,
      itemBuilder: (_) => [
        for (final r in kPlaybackRates)
          PopupMenuItem(value: r, child: Text('${_rateLabel(r)}  speed')),
      ],
      child: FlatPill(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_rateLabel(_rate)),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, size: 16),
          ],
        ),
      ),
    );
    // The theme's raised icon keys are reset here: this row uses flat icons.
    return Theme(
      data: Theme.of(context).copyWith(iconButtonTheme: const IconButtonThemeData()),
      child: LayoutBuilder(
        builder: (context, box) {
          final left = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...transport,
              if (widget.clock != null) ...[const SizedBox(width: Spacing.md), widget.clock!],
            ],
          );
          final right = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...widget.extras,
              const SizedBox(width: Spacing.xs),
              speed,
            ],
          );
          if (box.maxWidth.isFinite && box.maxWidth >= 560) {
            return Row(children: [left, const Spacer(), right]);
          }
          return Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            runSpacing: Spacing.xs,
            children: [left, right],
          );
        },
      ),
    );
  }
}

/// A flat text pill on the playback bar (speed menu, rings toggle): no raised face, a soft
/// fill on hover and, for a toggle ([on] not null), a small dot that lights up when on.
class FlatPill extends StatelessWidget {
  const FlatPill({super.key, required this.child, this.onTap, this.on, this.tooltip});

  final Widget child;
  final VoidCallback? onTap;
  final bool? on;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final content = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinTouchTarget, minWidth: kMinTouchTarget),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.sm + 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (on != null) ...[
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on! ? StatusColors.of(context).inCall : p.text3.withValues(alpha: 0.4),
                ),
              ),
              const SizedBox(width: 6),
            ],
            DefaultTextStyle.merge(
              style: TextStyle(color: p.text2, fontSize: 13, fontWeight: FontWeight.w500),
              child: IconTheme.merge(
                data: IconThemeData(color: p.text2),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
    if (onTap == null) return content;
    Widget pill = Semantics(
      button: true,
      toggled: on,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap, child: content),
      ),
    );
    if (tooltip != null) pill = Tooltip(message: tooltip, child: pill);
    return pill;
  }
}

/// Keyboard control for the whole results screen (T4.11): Space plays or pauses, the left
/// and right arrows step one frame, J and L jump to the previous and next stroke. Only while no control inside has focus: a focused
/// button, chip or list keeps Space and the arrows for itself.
class PlaybackShortcuts extends StatelessWidget {
  const PlaybackShortcuts({
    super.key,
    required this.target,
    required this.fps,
    required this.child,
    this.onPreviousShot,
    this.onNextShot,
  });

  final PlaybackTarget target;
  final double fps;
  final Widget child;

  /// J and L: the stroke before / after the playback position.
  final VoidCallback? onPreviousShot;
  final VoidCallback? onNextShot;

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
          LogicalKeyboardKey.keyJ when event is KeyDownEvent => onPreviousShot,
          LogicalKeyboardKey.keyL when event is KeyDownEvent => onNextShot,
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
