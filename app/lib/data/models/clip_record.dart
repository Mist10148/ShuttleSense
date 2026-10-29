import 'json.dart';

typedef CourtPoint = ({double x, double y});

/// Dart mirror of the parts of the clip record the app displays.
/// Source of truth: backend/shuttlesense/schema.py and docs/DATA_FORMAT.md.
class ClipRecord {
  const ClipRecord({
    required this.schemaVersion,
    required this.clipId,
    required this.fps,
    required this.width,
    required this.height,
    required this.numFrames,
    required this.frames,
    required this.hits,
    this.courtCorners,
    this.score,
    this.summary,
  });

  final String schemaVersion;
  final String clipId;
  final double fps;
  final int width;
  final int height;
  final int numFrames;
  final List<CourtPoint>? courtCorners;
  final List<FrameInfo> frames;
  final List<Hit> hits;
  final Score? score;
  final Summary? summary;

  int frameAt(Duration position) => (position.inMicroseconds * fps / Duration.microsecondsPerSecond)
      .floor()
      .clamp(0, numFrames == 0 ? 0 : numFrames - 1);

  FrameInfo? frame(int index) => index >= 0 && index < frames.length ? frames[index] : null;

  /// The latest hit at or before [frameIndex].
  Hit? hitAt(int frameIndex) {
    Hit? last;
    for (final h in hits) {
      if (h.frame > frameIndex) break;
      last = h;
    }
    return last;
  }

  factory ClipRecord.fromJson(Json j) {
    final court = j['court'] as Json?;
    return ClipRecord(
      schemaVersion: j['schema_version'] as String,
      clipId: j['clip_id'] as String,
      fps: asDouble(j['fps'])!,
      width: asInt(j['width'])!,
      height: asInt(j['height'])!,
      numFrames: asInt(j['num_frames'])!,
      courtCorners: court == null
          ? null
          : (court['corners_px'] as List<dynamic>).map((p) => asPoint(p)!).toList(),
      frames: asList(j['frames']).map(FrameInfo.fromJson).toList(),
      hits: asList(j['hits']).map(Hit.fromJson).toList(),
      score: j['score'] == null ? null : Score.fromJson(j['score'] as Json),
      summary: j['summary'] == null ? null : Summary.fromJson(j['summary'] as Json),
    );
  }
}

class FrameInfo {
  const FrameInfo({
    required this.frame,
    this.nearPos,
    this.farPos,
    this.shuttlePos,
    this.shuttleSpeedKmh,
    this.rallyState,
  });

  final int frame;

  /// Court-plane positions in meters (null without calibration).
  final CourtPoint? nearPos;
  final CourtPoint? farPos;
  final CourtPoint? shuttlePos;
  final double? shuttleSpeedKmh;

  /// in_play or between_rallies.
  final String? rallyState;

  factory FrameInfo.fromJson(Json j) {
    final pos = j['court_positions'] as Json?;
    return FrameInfo(
      frame: asInt(j['frame'])!,
      nearPos: asPoint(pos?['near']),
      farPos: asPoint(pos?['far']),
      shuttlePos: asPoint(pos?['shuttle']),
      shuttleSpeedKmh: asDouble(j['shuttle_speed_kmh']),
      rallyState: j['rally_state'] as String?,
    );
  }
}

class Hit {
  const Hit({
    required this.id,
    required this.frame,
    required this.timeS,
    required this.player,
    this.stroke,
    this.confidence,
    this.speedKmh,
    this.tip,
    this.rallyIndex,
  });

  final int id;
  final int frame;
  final double timeS;

  /// near or far.
  final String player;
  final String? stroke;
  final double? confidence;
  final double? speedKmh;

  /// First failed-rule tip from the form feedback, if any.
  final String? tip;
  final int? rallyIndex;

  Duration get position => Duration(microseconds: (timeS * Duration.microsecondsPerSecond).round());

  factory Hit.fromJson(Json j) {
    String? tip;
    for (final fb in asList(j['feedback'])) {
      if (fb['tip'] != null) {
        tip = fb['tip'] as String;
        break;
      }
    }
    return Hit(
      id: asInt(j['id'])!,
      frame: asInt(j['frame'])!,
      timeS: asDouble(j['time_s'])!,
      player: j['player'] as String,
      stroke: j['stroke'] as String?,
      confidence: asDouble(j['confidence']),
      speedKmh: asDouble(j['speed_kmh']),
      tip: tip,
      rallyIndex: asInt(j['rally_index']),
    );
  }
}

class Score {
  const Score({required this.near, required this.far});

  final int near;
  final int far;

  factory Score.fromJson(Json j) => Score(near: asInt(j['near'])!, far: asInt(j['far'])!);
}

class Summary {
  const Summary({required this.totalHits, required this.strokeCounts, this.peakSpeedKmh});

  final int totalHits;
  final Map<String, int> strokeCounts;
  final double? peakSpeedKmh;

  factory Summary.fromJson(Json j) => Summary(
    totalHits: asInt(j['total_hits']) ?? 0,
    strokeCounts: (j['stroke_counts'] as Json? ?? const {}).map(
      (k, v) => MapEntry(k, (v as num).toInt()),
    ),
    peakSpeedKmh: asDouble(j['peak_speed_kmh']),
  );
}

/// Display names for the six stroke classes.
const kStrokeLabels = <String, String>{
  'smash': 'Smash',
  'clear': 'Clear',
  'drop': 'Drop',
  'net_shot': 'Net shot',
  'lift': 'Lift',
  'serve': 'Serve',
};
