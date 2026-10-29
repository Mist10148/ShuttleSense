import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../data/api_client.dart';
import '../../data/models/video_info.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/message_view.dart';

typedef Corner = ({double x, double y});

const kCornerNames = ['Near left', 'Near right', 'Far right', 'Far left'];

/// F9 / FR-9: tap the 4 singles-court corners on the first frame.
/// Coordinates are sent in video pixels, in the order of docs/DATA_FORMAT.md.
class CalibrationScreen extends ConsumerStatefulWidget {
  const CalibrationScreen({super.key, required this.videoId});

  final String videoId;

  @override
  ConsumerState<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends ConsumerState<CalibrationScreen> {
  final List<Corner> _corners = [];
  bool _submitting = false;
  String? _error;

  Future<void> _start({required bool withCorners}) async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final job = await ref
          .read(apiClientProvider)
          .createJob(
            videoId: widget.videoId,
            options: ref.read(pendingJobOptionsProvider),
            corners: withCorners ? List.of(_corners) : null,
          );
      if (mounted) context.go(Routes.job(job.id));
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = ref.watch(videoProvider(widget.videoId));
    final next = _corners.length < 4 ? kCornerNames[_corners.length] : null;

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
              child: Text(
                next == null
                    ? 'All 4 corners set. Start processing or undo to adjust.'
                    : 'Tap the $next corner of the singles court '
                          '(${_corners.length + 1} of 4). Pinch or scroll to zoom.',
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: _FrameCanvas(info: info, corners: _corners, onTap: _onTap),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton.icon(
                  onPressed: _corners.length == 4 && !_submitting
                      ? () => _start(withCorners: true)
                      : null,
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

  void _onTap(Corner c) {
    if (_corners.length < 4) setState(() => _corners.add(c));
  }
}

class _FrameCanvas extends ConsumerWidget {
  const _FrameCanvas({required this.info, required this.corners, required this.onTap});

  final VideoInfo info;
  final List<Corner> corners;
  final ValueChanged<Corner> onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiClientProvider);
    return InteractiveViewer(
      maxScale: 6,
      child: Center(
        child: AspectRatio(
          aspectRatio: info.aspectRatio,
          child: LayoutBuilder(
            builder: (context, box) {
              final scale = info.width / box.maxWidth;
              return GestureDetector(
                onTapUp: (d) =>
                    onTap((x: d.localPosition.dx * scale, y: d.localPosition.dy * scale)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      api.frameUrl(info.id, 0),
                      headers: api.authHeaders,
                      fit: BoxFit.fill,
                      errorBuilder: (_, _, _) =>
                          const MessageView(icon: Icons.broken_image, message: 'Frame unavailable'),
                    ),
                    CustomPaint(painter: _CornersPainter(corners, 1 / scale)),
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

class _CornersPainter extends CustomPainter {
  _CornersPainter(this.corners, this.scale);

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
  bool shouldRepaint(_CornersPainter old) => old.corners.length != corners.length;
}
