import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/server_config.dart';
import '../../core/responsive/breakpoints.dart';
import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/video_info.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import '../../shared/widgets/page_scaffold.dart';
import '../../shared/widgets/surfaces.dart';
import '../upload/upload_controller.dart';
import '../../core/theme/tokens.dart';
import '../../shared/widgets/helper_text.dart';
import '../../shared/widgets/data_display.dart';

typedef Corner = ({double x, double y});

const kCornerNames = ['Near left', 'Near right', 'Far right', 'Far left'];

/// A corner handle grabs the pointer within this distance (dp).
const double kHandleRadius = 24;

/// Mirrors backend/shuttlesense/court/homography.py validate_corners: 4 points forming a
/// convex quadrilateral when visited in order (either winding).
bool isConvex(List<Corner> points) {
  if (points.length != 4) return false;
  final signs = <bool>{};
  for (var i = 0; i < 4; i++) {
    final a = points[i], b = points[(i + 1) % 4], c = points[(i + 2) % 4];
    final cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
    if (cross == 0) return false;
    signs.add(cross > 0);
  }
  return signs.length == 1;
}

/// F9 / FR-9: tap the 4 singles-court corners on a frame of the video.
/// Coordinates are sent in source video pixels, in the order of docs/DATA_FORMAT.md.
class CalibrationScreen extends ConsumerStatefulWidget {
  const CalibrationScreen({super.key, required this.videoId});

  final String videoId;

  @override
  ConsumerState<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends ConsumerState<CalibrationScreen> {
  final List<Corner> _corners = [];
  int _frame = 0;

  /// Slider position while dragging; the frame is only fetched once the drag ends, so the
  /// server does not decode a frame for every tick.
  double? _sliding;
  bool _submitting = false;
  String? _error;

  Future<void> _start({required bool withCorners}) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    // Skipping drops the court overlays and the referee layer, which need the corners.
    final options = ref
        .read(pendingJobOptionsProvider)
        .copyWith(calibrate: withCorners)
        .submittable(ref.read(healthProvider).valueOrNull);
    try {
      final job = await ref
          .read(apiClientProvider)
          .createJob(
            videoId: widget.videoId,
            options: options,
            corners: withCorners ? List.of(_corners) : null,
          );
      if (mounted) context.go(Routes.job(job.id));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = ref.watch(videoProvider(widget.videoId));
    final window = Breakpoints.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            Breakpoints.gutter(window),
            Spacing.xl,
            Breakpoints.gutter(window),
            Spacing.lg,
          ),
          child: MaxWidth(
            maxWidth: 1200,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader(
                  title: 'Court calibration',
                  actions: [
                    IconButton(
                      tooltip: 'Undo',
                      onPressed: _corners.isEmpty ? null : () => setState(_corners.removeLast),
                      icon: const Icon(Icons.undo),
                    ),
                    IconButton(
                      tooltip: 'Reset',
                      onPressed: _corners.isEmpty ? null : () => setState(_corners.clear),
                      icon: const Icon(Icons.restart_alt),
                    ),
                    // On a phone Skip sits under Start processing, leaving the title room.
                    if (window == WindowClass.expanded) _skip(),
                  ],
                ),
                const SizedBox(height: Spacing.lg),
                Expanded(
                  child: video.when(
                    loading: () => const Skeleton(height: double.infinity, radius: Radii.lg),
                    error: (e, _) => MessageView(icon: Icons.error_outline, message: e.toString()),
                    data: (info) => window == WindowClass.expanded ? _wide(info) : _narrow(info),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int? get _next => _corners.length < 4 ? _corners.length : null;

  /// Laptop: the frame on the left, the corner checklist and the start button beside it.
  Widget _wide(VideoInfo info) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: _frameCard(info)),
      const SizedBox(width: Spacing.lg),
      SizedBox(
        width: 320,
        child: AppCard(
          child: Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: CornerDiagram(next: _next, size: const Size(96, 128)),
                ),
                const SizedBox(height: Spacing.lg),
                _instruction(),
                const SizedBox(height: Spacing.md),
                for (var i = 0; i < 4; i++)
                  _CornerStep(index: i, done: i < _corners.length, next: i == _next),
                const SizedBox(height: Spacing.md),
                _help(),
                const Spacer(),
                ..._footer(),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  /// Phone and tablet: instruction, frame, then the start button, in one column.
  Widget _narrow(VideoInfo info) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          CornerDiagram(next: _next),
          const SizedBox(width: Spacing.md),
          Expanded(child: _instruction()),
        ],
      ),
      const SizedBox(height: Spacing.md),
      Expanded(child: _frameCard(info)),
      const SizedBox(height: Spacing.sm),
      _help(),
      ..._footer(),
      Center(child: _skip()),
    ],
  );

  Widget _skip() => TextButton(
    onPressed: _submitting ? null : () => _start(withCorners: false),
    child: const Text('Skip'),
  );

  Widget _frameCard(VideoInfo info) => AppCard(
    padding: const EdgeInsets.all(Spacing.md),
    child: Expanded(
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.md),
              child: _VideoFrameCanvas(
                info: info,
                frame: _frame,
                corners: _corners,
                onTap: (c) {
                  if (_corners.length < 4) setState(() => _corners.add(c));
                },
                onMove: (i, c) => setState(() => _corners[i] = c),
              ),
            ),
          ),
          if (info.numFrames > 1)
            Row(
              children: [
                const Text('Frame'),
                Expanded(
                  child: Slider(
                    value: _sliding ?? _frame.toDouble(),
                    max: (info.numFrames - 1).toDouble(),
                    divisions: (info.numFrames - 1).clamp(1, 100),
                    label:
                        '${((_sliding ?? _frame) / (info.fps == 0 ? 30 : info.fps)).toStringAsFixed(1)} s',
                    semanticFormatterCallback: (v) => 'Frame ${v.round()}',
                    onChanged: (v) => setState(() => _sliding = v),
                    onChangeEnd: (v) => setState(() {
                      _sliding = null;
                      _frame = v.round();
                    }),
                  ),
                ),
              ],
            ),
        ],
      ),
    ),
  );

  Widget _instruction() {
    final next = _next;
    final crossed = next == null && !isConvex(_corners);
    return Text(
      next == null
          ? (crossed
                ? 'The corners cross over. Drag them so they go around the '
                      'court in order: near left, near right, far right, far left.'
                : 'All 4 corners set. Drag a corner to adjust, then start.')
          : 'Tap the ${kCornerNames[next]} corner of the singles court '
                '(${next + 1} of 4), also for doubles. Pinch or scroll to zoom.',
      style: crossed ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
    );
  }

  Widget _help() => Text(
    'Skipping calibration disables player detection. For best accuracy, use a fixed camera '
    'and keep the whole court visible.',
    style: Theme.of(context).textTheme.bodySmall,
  );

  List<Widget> _footer() => [
    if (_error != null)
      Padding(
        padding: const EdgeInsets.only(top: Spacing.sm),
        child: HelperText(_error!, error: true),
      ),
    const SizedBox(height: Spacing.md),
    FilledButton.icon(
      onPressed: isConvex(_corners) && !_submitting ? () => _start(withCorners: true) : null,
      icon: const Icon(Icons.play_arrow),
      label: const Text('Start processing'),
    ),
  ];
}

/// One line of the corner checklist: a brand-green check once set, a filled ring for the
/// corner to tap next.
class _CornerStep extends StatelessWidget {
  const _CornerStep({required this.index, required this.done, required this.next});

  final int index;
  final bool done;
  final bool next;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        children: [
          Icon(
            done
                ? Icons.check_circle
                : (next ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            size: 20,
            color: done ? p.brand : (next ? p.ink : p.text3),
          ),
          const SizedBox(width: Spacing.sm),
          Text(
            '${index + 1}. ${kCornerNames[index]}',
            style: next ? text.titleSmall : text.bodyMedium?.copyWith(color: p.text2),
          ),
        ],
      ),
    );
  }
}

/// Court sketch highlighting the corner to tap next.
class CornerDiagram extends StatelessWidget {
  const CornerDiagram({super.key, required this.next, this.size = const Size(44, 60)});

  /// Index into [kCornerNames], or null when all corners are set.
  final int? next;
  final Size size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: next == null ? 'All corners set' : 'Next corner: ${kCornerNames[next!]}',
      child: SizedBox.fromSize(
        size: size,
        child: CustomPaint(
          painter: _DiagramPainter(next: next, line: scheme.outline, accent: scheme.primary),
        ),
      ),
    );
  }
}

class _DiagramPainter extends CustomPainter {
  _DiagramPainter({required this.next, required this.line, required this.accent});

  final int? next;
  final Color line;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    // Seen from behind the near baseline: near side wider, at the bottom.
    final pts = [
      Offset(2, size.height - 2),
      Offset(size.width - 2, size.height - 2),
      Offset(size.width * 0.8, 2),
      Offset(size.width * 0.2, 2),
    ];
    final paint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawPath(Path()..addPolygon(pts, true), paint);
    canvas.drawLine(
      Offset(size.width * 0.1, size.height / 2),
      Offset(size.width * 0.9, size.height / 2),
      paint,
    );
    for (var i = 0; i < 4; i++) {
      canvas.drawCircle(pts[i], i == next ? 5 : 2.5, Paint()..color = i == next ? accent : line);
    }
  }

  @override
  bool shouldRepaint(_DiagramPainter old) => old.next != next || old.accent != accent;
}

/// A frame of an uploaded video, fetched from the server.
class _VideoFrameCanvas extends ConsumerWidget {
  const _VideoFrameCanvas({
    required this.info,
    required this.frame,
    required this.corners,
    required this.onTap,
    required this.onMove,
  });

  final VideoInfo info;
  final int frame;
  final List<Corner> corners;
  final ValueChanged<Corner> onTap;
  final void Function(int index, Corner corner) onMove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // "Change server" clears the config; this tree may rebuild once before the redirect.
    if (ref.watch(serverConfigProvider) == null) return const SizedBox.shrink();
    final api = ref.watch(apiClientProvider);
    return CornerCanvas(
      image: NetworkImage(api.frameUrl(info.id, frame), headers: api.authHeaders),
      width: info.width,
      height: info.height,
      corners: corners,
      onTap: onTap,
      onMove: onMove,
    );
  }
}

/// Tap and drag the 4 court corners on [image], in [width] x [height] image pixels.
/// Used on a frame of an uploaded video and on a still from the live camera.
class CornerCanvas extends StatefulWidget {
  const CornerCanvas({
    super.key,
    required this.image,
    required this.width,
    required this.height,
    required this.corners,
    required this.onTap,
    required this.onMove,
    this.overlayPainter,
  });

  /// Optional preview painted in image coordinates, before the corner handles.
  final CustomPainter Function(double scale)? overlayPainter;
  final ImageProvider image;
  final int width;
  final int height;
  final List<Corner> corners;
  final ValueChanged<Corner> onTap;
  final void Function(int index, Corner corner) onMove;

  @override
  State<CornerCanvas> createState() => _CornerCanvasState();
}

class _CornerCanvasState extends State<CornerCanvas> {
  int? _dragging;
  Offset? _loupe;

  /// Zoom: never below the whole frame, never past 5×, never showing empty space beside it.
  static const double _minScale = 1, _maxScale = 5;
  final _view = TransformationController();
  Size _viewport = Size.zero;

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  double get _scale => _view.value.getMaxScaleOnAxis();

  /// Scales by [factor] around [focal] (in the zoomed picture's own coordinates), keeping the
  /// picture filling the view.
  void _zoom(double factor, Offset focal) {
    final scale = (_scale * factor).clamp(_minScale, _maxScale);
    final k = scale / _scale;
    if (k == 1) return;
    final next = _view.value.clone()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(k, k, 1, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    _view.value = _clamped(next);
  }

  Matrix4 _clamped(Matrix4 m) {
    final scale = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    final minX = _viewport.width * (1 - scale), minY = _viewport.height * (1 - scale);
    return Matrix4.identity()
      ..translateByDouble(t.x.clamp(minX, 0), t.y.clamp(minY, 0), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// The view's centre in the picture's own coordinates (for the + and − keys).
  Offset _centre() {
    final inverse = Matrix4.inverted(_view.value);
    final c = MatrixUtils.transformPoint(
      inverse,
      Offset(_viewport.width / 2, _viewport.height / 2),
    );
    return c;
  }

  /// A plain wheel scrolls the page; Ctrl / ⌘ + wheel zooms the picture.
  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    final zoom = keys.isControlPressed || keys.isMetaPressed;
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      final scroll = e as PointerScrollEvent;
      if (zoom) {
        _zoom(math.exp(-scroll.scrollDelta.dy / 300), scroll.localPosition);
      } else {
        Scrollable.maybeOf(context)?.position.pointerScroll(scroll.scrollDelta.dy);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width, height = widget.height;
    final viewer = ClipRRect(
      borderRadius: BorderRadius.circular(Radii.md),
      child: InteractiveViewer(
        transformationController: _view,
        minScale: _minScale,
        maxScale: _maxScale,
        boundaryMargin: EdgeInsets.zero,
        panEnabled: _dragging == null,
        child: Listener(
          onPointerSignal: _onSignal,
          child: AspectRatio(
            aspectRatio: height == 0 ? 16 / 9 : width / height,
            child: LayoutBuilder(
              builder: (context, box) {
                final scale = width / box.maxWidth; // image px per dp
                Corner toVideo(Offset p) => (
                  x: (p.dx * scale).clamp(0, width.toDouble()),
                  y: (p.dy * scale).clamp(0, height.toDouble()),
                );
                Offset toCanvas(Corner c) => Offset(c.x / scale, c.y / scale);
                return GestureDetector(
                  onTapUp: (d) {
                    // The handles are raw Listeners, outside the gesture arena, so a tap on one
                    // reaches this detector too: it must not drop a new corner on top of it.
                    final onHandle = widget.corners.any(
                      (c) => (toCanvas(c) - d.localPosition).distance <= kHandleRadius,
                    );
                    if (!onHandle) widget.onTap(toVideo(d.localPosition));
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image(
                        image: widget.image,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const MessageView(
                          icon: Icons.broken_image,
                          message: 'Frame unavailable',
                        ),
                      ),
                      if (widget.overlayPainter != null)
                        IgnorePointer(
                          child: CustomPaint(painter: widget.overlayPainter!(1 / scale)),
                        ),
                      CustomPaint(painter: CornersPainter(widget.corners, 1 / scale)),
                      for (var i = 0; i < widget.corners.length; i++)
                        Positioned(
                          left: toCanvas(widget.corners[i]).dx - kHandleRadius,
                          top: toCanvas(widget.corners[i]).dy - kHandleRadius,
                          width: kHandleRadius * 2,
                          height: kHandleRadius * 2,
                          child: Semantics(
                            label: '${kCornerNames[i]} corner handle',
                            // Raw pointer events, so the handle moves even though the zoomable
                            // viewer around it also listens for drags (panning is off meanwhile).
                            child: Listener(
                              key: ValueKey('corner-$i'),
                              behavior: HitTestBehavior.opaque,
                              onPointerDown: (_) => setState(() => _dragging = i),
                              onPointerMove: (e) {
                                final p = toCanvas(widget.corners[i]) + e.localDelta;
                                widget.onMove(i, toVideo(p));
                                setState(() => _loupe = p);
                              },
                              onPointerUp: (_) => setState(() {
                                _dragging = null;
                                _loupe = null;
                              }),
                              onPointerCancel: (_) => setState(() {
                                _dragging = null;
                                _loupe = null;
                              }),
                            ),
                          ),
                        ),
                      if (_loupe != null)
                        Positioned(
                          left: _loupe!.dx - 50,
                          top: _loupe!.dy - 130,
                          child: const RawMagnifier(
                            size: Size(100, 100),
                            magnificationScale: 2.5,
                            focalPointOffset: Offset(0, 80),
                            decoration: MagnifierDecoration(
                              shape: CircleBorder(side: BorderSide(color: Colors.white, width: 2)),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    final aspect = height == 0 ? 16 / 9 : width / height;
    final picture = AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(
        builder: (context, box) {
          _viewport = box.biggest;
          return viewer;
        },
      ),
    );
    // Zoom keys and a hint under the picture, never over it (a corner near the bottom edge
    // stays tappable).
    final bar = Row(
      children: [
        Expanded(
          child: _ZoomHint(
            text: kIsWeb || defaultTargetPlatform != TargetPlatform.android
                ? 'Ctrl + scroll or pinch to zoom'
                : 'Pinch to zoom',
          ),
        ),
        _ZoomBar(
          onOut: () => _zoom(1 / 1.5, _centre()),
          onIn: () => _zoom(1.5, _centre()),
          onFit: () => _view.value = Matrix4.identity(),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) => box.hasBoundedHeight
          ? Column(
              children: [
                Expanded(child: Center(child: picture)),
                const SizedBox(height: Spacing.xs),
                bar,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                picture,
                const SizedBox(height: Spacing.xs),
                bar,
              ],
            ),
    );
  }
}

/// A short hint on how to zoom, on a dark glass strip so it reads over any frame.
class _ZoomHint extends StatelessWidget {
  const _ZoomHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.of(context);
    return Row(
      children: [
        Icon(Icons.zoom_in_rounded, size: 16, color: p.text3),
        const SizedBox(width: Spacing.xs),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.text3),
          ),
        ),
      ],
    );
  }
}

/// Zoom out, zoom in and fit the whole frame.
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({required this.onOut, required this.onIn, required this.onFit});

  final VoidCallback onOut, onIn, onFit;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(tooltip: 'Zoom out', onPressed: onOut, icon: const Icon(Icons.remove_rounded)),
      const SizedBox(width: Spacing.xs),
      IconButton(tooltip: 'Zoom in', onPressed: onIn, icon: const Icon(Icons.add_rounded)),
      const SizedBox(width: Spacing.xs),
      IconButton(
        tooltip: 'Fit the whole frame',
        onPressed: onFit,
        icon: const Icon(Icons.fit_screen_rounded),
      ),
    ],
  );
}

class CornersPainter extends CustomPainter {
  CornersPainter(this.corners, this.scale);

  final List<Corner> corners;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [for (final c in corners) Offset(c.x * scale, c.y * scale)];
    final line = Paint()
      ..color = OverlayColors.corners
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var i = 0; i + 1 < points.length; i++) {
      canvas.drawLine(points[i], points[i + 1], line);
    }
    if (points.length == 4) canvas.drawLine(points[3], points[0], line);
    final ring = Paint()
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(points[i], 10, Paint()..color = OverlayColors.cornerMarkers[i]);
      canvas.drawCircle(points[i], 10, ring);
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
            color: OverlayColors.cornerLabel,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, points[i] - Offset(label.width / 2, label.height / 2));
    }
  }

  @override
  bool shouldRepaint(CornersPainter old) => true;
}
