import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/video_info.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';
import '../upload/upload_controller.dart';

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
    final next = _corners.length < 4 ? _corners.length : null;
    final convex = isConvex(_corners);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Court calibration'),
        actions: [
          IconButton(
            tooltip: 'Undo',
            onPressed: _corners.isEmpty ? null : () => setState(_corners.removeLast),
            icon: const Icon(Icons.undo),
          ),
          TextButton(
            onPressed: _submitting ? null : () => _start(withCorners: false),
            child: const Text('Skip'),
          ),
        ],
      ),
      body: video.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => MessageView(icon: Icons.error_outline, message: e.toString()),
        data: (info) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  CornerDiagram(next: next),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      next == null
                          ? (convex
                                ? 'All 4 corners set. Drag a corner to adjust, then start.'
                                : 'The corners cross over. Drag them so they go around the '
                                      'court in order: near left, near right, far right, far left.')
                          : 'Tap the ${kCornerNames[next]} corner of the singles court '
                                '(${next + 1} of 4). Pinch or scroll to zoom.',
                      style: next == null && !convex
                          ? TextStyle(color: theme.colorScheme.error)
                          : null,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _FrameCanvas(
                info: info,
                frame: _frame,
                corners: _corners,
                onTap: (c) {
                  if (_corners.length < 4) setState(() => _corners.add(c));
                },
                onMove: (i, c) => setState(() => _corners[i] = c),
              ),
            ),
            if (info.numFrames > 1)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Text('Frame'),
                    Expanded(
                      child: Slider(
                        value: _frame.toDouble(),
                        max: (info.numFrames - 1).toDouble(),
                        divisions: (info.numFrames - 1).clamp(1, 100),
                        label: '${(_frame / (info.fps == 0 ? 30 : info.fps)).toStringAsFixed(1)} s',
                        semanticFormatterCallback: (v) => 'Frame ${v.round()}',
                        onChanged: (v) => setState(() => _frame = v.round()),
                      ),
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: convex && !_submitting ? () => _start(withCorners: true) : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start processing'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small court sketch highlighting the corner to tap next.
class CornerDiagram extends StatelessWidget {
  const CornerDiagram({super.key, required this.next});

  /// Index into [kCornerNames], or null when all corners are set.
  final int? next;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: next == null ? 'All corners set' : 'Next corner: ${kCornerNames[next!]}',
      child: SizedBox(
        width: 44,
        height: 60,
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

class _FrameCanvas extends ConsumerStatefulWidget {
  const _FrameCanvas({
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
  ConsumerState<_FrameCanvas> createState() => _FrameCanvasState();
}

class _FrameCanvasState extends ConsumerState<_FrameCanvas> {
  int? _dragging;
  Offset? _loupe;

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(apiClientProvider);
    final info = widget.info;
    return InteractiveViewer(
      maxScale: 6,
      panEnabled: _dragging == null,
      child: Center(
        child: AspectRatio(
          aspectRatio: info.aspectRatio,
          child: LayoutBuilder(
            builder: (context, box) {
              final scale = info.width / box.maxWidth; // video px per dp
              Corner toVideo(Offset p) => (
                x: (p.dx * scale).clamp(0, info.width.toDouble()),
                y: (p.dy * scale).clamp(0, info.height.toDouble()),
              );
              Offset toCanvas(Corner c) => Offset(c.x / scale, c.y / scale);
              return GestureDetector(
                onTapUp: (d) => widget.onTap(toVideo(d.localPosition)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      api.frameUrl(info.id, widget.frame),
                      headers: api.authHeaders,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          const MessageView(icon: Icons.broken_image, message: 'Frame unavailable'),
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
    );
  }
}

class CornersPainter extends CustomPainter {
  CornersPainter(this.corners, this.scale);

  final List<Corner> corners;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [for (final c in corners) Offset(c.x * scale, c.y * scale)];
    final line = Paint()
      ..color = Colors.yellowAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var i = 0; i + 1 < points.length; i++) {
      canvas.drawLine(points[i], points[i + 1], line);
    }
    if (points.length == 4) canvas.drawLine(points[3], points[0], line);
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(points[i], 7, Paint()..color = Colors.yellowAccent);
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, points[i] - Offset(label.width / 2, label.height / 2));
    }
  }

  @override
  bool shouldRepaint(CornersPainter old) => true;
}
