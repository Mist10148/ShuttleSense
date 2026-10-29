import 'json.dart';

/// POST /videos and GET /videos/{id} (docs/API.md).
class VideoInfo {
  const VideoInfo({
    required this.id,
    required this.filename,
    required this.sizeBytes,
    required this.fps,
    required this.width,
    required this.height,
    required this.numFrames,
    required this.durationS,
  });

  final String id;
  final String filename;
  final int sizeBytes;
  final double fps;
  final int width;
  final int height;
  final int numFrames;
  final double durationS;

  double get aspectRatio => height == 0 ? 16 / 9 : width / height;

  factory VideoInfo.fromJson(Json j) => VideoInfo(
    id: j['id'] as String,
    filename: j['filename'] as String,
    sizeBytes: asInt(j['size_bytes'])!,
    fps: asDouble(j['fps'])!,
    width: asInt(j['width'])!,
    height: asInt(j['height'])!,
    numFrames: asInt(j['num_frames'])!,
    durationS: asDouble(j['duration_s'])!,
  );
}
