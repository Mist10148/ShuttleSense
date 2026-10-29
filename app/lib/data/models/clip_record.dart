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
    this.rallies = const [],
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
  final List<Rally> rallies;
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

  /// The rally containing [frameIndex], if any.
  Rally? rallyAt(int frameIndex) {
    for (final r in rallies) {
      if (r.startFrame <= frameIndex && frameIndex <= r.endFrame) return r;
    }
    return null;
  }

  /// Score shown at [frameIndex]: after the last rally that ended at or before it.
  /// Before the first rally ends this is the starting score. Null without a referee.
  ScorePair? scoreAt(int frameIndex) {
    if (score == null) return null;
    var current = const ScorePair(near: 0, far: 0);
    final first = rallies.where((r) => r.scoreAfter != null).firstOrNull;
    if (first != null) {
      final r0 = rallies.first;
      current = ScorePair(
        near: first.scoreAfter!.near - (r0.winner == 'near' ? 1 : 0),
        far: first.scoreAfter!.far - (r0.winner == 'far' ? 1 : 0),
      );
    }
    for (final r in rallies) {
      if (r.endFrame <= frameIndex && r.scoreAfter != null) current = r.scoreAfter!;
    }
    return current;
  }

  /// Strokes so far in the rally containing [frameIndex] (whole clip without rallies).
  int strokesSoFar(int frameIndex) {
    var start = 0;
    for (final r in rallies) {
      if (r.startFrame <= frameIndex) start = r.startFrame;
    }
    return hits.where((h) => h.frame >= start && h.frame <= frameIndex).length;
  }

  ClipRecord copyWith({List<Rally>? rallies, Score? score}) => ClipRecord(
    schemaVersion: schemaVersion,
    clipId: clipId,
    fps: fps,
    width: width,
    height: height,
    numFrames: numFrames,
    frames: frames,
    hits: hits,
    rallies: rallies ?? this.rallies,
    courtCorners: courtCorners,
    score: score ?? this.score,
    summary: summary,
  );

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
      rallies: asList(j['rallies']).map(Rally.fromJson).toList(),
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
    this.feedback = const [],
    this.classProbs = const {},
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

  /// Form feedback rules evaluated for this hit (docs/FEEDBACK_RULES.md).
  final List<FeedbackItem> feedback;
  final Map<String, double> classProbs;
  final int? rallyIndex;

  /// First failed-rule tip from the form feedback, if any.
  String? get tip {
    for (final fb in feedback) {
      if (!fb.passed && fb.tip != null) return fb.tip;
    }
    return null;
  }

  /// Low-confidence predictions are shown with a "?".
  bool get uncertain => confidence != null && confidence! < 0.5;

  Duration get position => Duration(microseconds: (timeS * Duration.microsecondsPerSecond).round());

  factory Hit.fromJson(Json j) {
    return Hit(
      id: asInt(j['id'])!,
      frame: asInt(j['frame'])!,
      timeS: asDouble(j['time_s'])!,
      player: j['player'] as String,
      stroke: j['stroke'] as String?,
      confidence: asDouble(j['confidence']),
      speedKmh: asDouble(j['speed_kmh']),
      feedback: asList(j['feedback']).map(FeedbackItem.fromJson).toList(),
      classProbs: (j['class_probs'] as Map? ?? const {}).map(
        (k, v) => MapEntry(k as String, (v as num).toDouble()),
      ),
      rallyIndex: asInt(j['rally_index']),
    );
  }
}

class FeedbackItem {
  const FeedbackItem({required this.rule, required this.passed, this.tip});

  final String rule;
  final bool passed;
  final String? tip;

  /// "elbow_extension" -> "Elbow extension".
  String get label {
    final words = rule.replaceAll('_', ' ');
    return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
  }

  factory FeedbackItem.fromJson(Json j) => FeedbackItem(
    rule: j['rule'] as String,
    passed: j['passed'] as bool,
    tip: j['tip'] as String?,
  );
}

class ScorePair {
  const ScorePair({required this.near, required this.far});

  final int near;
  final int far;

  factory ScorePair.fromJson(Json j) => ScorePair(near: asInt(j['near'])!, far: asInt(j['far'])!);

  @override
  bool operator ==(Object other) => other is ScorePair && other.near == near && other.far == far;

  @override
  int get hashCode => Object.hash(near, far);

  @override
  String toString() => '$near-$far';
}

class ScoreCorrection {
  const ScoreCorrection({required this.rallyIndex, this.winnerBefore, required this.winnerAfter});

  final int rallyIndex;
  final String? winnerBefore;
  final String winnerAfter;

  factory ScoreCorrection.fromJson(Json j) => ScoreCorrection(
    rallyIndex: asInt(j['rally_index'])!,
    winnerBefore: j['winner_before'] as String?,
    winnerAfter: j['winner_after'] as String,
  );
}

class Score extends ScorePair {
  const Score({required super.near, required super.far, this.corrections = const []});

  final List<ScoreCorrection> corrections;

  factory Score.fromJson(Json j) => Score(
    near: asInt(j['near'])!,
    far: asInt(j['far'])!,
    corrections: asList(j['corrections']).map(ScoreCorrection.fromJson).toList(),
  );
}

class Landing {
  const Landing({
    required this.x,
    required this.y,
    required this.inCourt,
    required this.confidence,
  });

  final double x;
  final double y;
  final bool inCourt;
  final double confidence;

  /// Close calls are never awarded automatically; the user confirms them.
  bool get uncertain => confidence < 0.5;

  factory Landing.fromJson(Json j) => Landing(
    x: asDouble(j['x_m'])!,
    y: asDouble(j['y_m'])!,
    inCourt: j['in_court'] as bool,
    confidence: asDouble(j['confidence'])!,
  );
}

class Rally {
  const Rally({
    required this.index,
    required this.startFrame,
    required this.endFrame,
    this.strokeCount = 0,
    this.landing,
    this.winner,
    this.scoreAfter,
  });

  final int index;
  final int startFrame;
  final int endFrame;
  final int strokeCount;
  final Landing? landing;

  /// near, far, or null when the rally is open or the call is uncertain.
  final String? winner;
  final ScorePair? scoreAfter;

  factory Rally.fromJson(Json j) => Rally(
    index: asInt(j['index'])!,
    startFrame: asInt(j['start_frame'])!,
    endFrame: asInt(j['end_frame'])!,
    strokeCount: asInt(j['stroke_count']) ?? 0,
    landing: j['landing'] == null ? null : Landing.fromJson(j['landing'] as Json),
    winner: j['winner'] as String?,
    scoreAfter: j['score_after'] == null ? null : ScorePair.fromJson(j['score_after'] as Json),
  );
}

/// PATCH /jobs/{id}/score response.
class ScoreUpdate {
  const ScoreUpdate({required this.score, required this.rallies});

  final Score score;
  final List<Rally> rallies;

  factory ScoreUpdate.fromJson(Json j) => ScoreUpdate(
    score: Score.fromJson(j['score'] as Json),
    rallies: asList(j['rallies']).map(Rally.fromJson).toList(),
  );
}

Map<String, int> _counts(Object? v) =>
    (v as Map? ?? const {}).map((k, v) => MapEntry(k as String, (v as num).toInt()));

class PlayerSummary {
  const PlayerSummary({required this.hits, required this.strokeCounts, this.peakSpeedKmh});

  final int hits;
  final Map<String, int> strokeCounts;
  final double? peakSpeedKmh;

  factory PlayerSummary.fromJson(Json j) => PlayerSummary(
    hits: asInt(j['hits']) ?? 0,
    strokeCounts: _counts(j['stroke_counts']),
    peakSpeedKmh: asDouble(j['peak_speed_kmh']),
  );
}

class Summary {
  const Summary({
    required this.totalHits,
    required this.strokeCounts,
    this.peakSpeedKmh,
    this.perPlayer = const {},
  });

  final int totalHits;
  final Map<String, int> strokeCounts;
  final double? peakSpeedKmh;

  /// Keyed by near / far.
  final Map<String, PlayerSummary> perPlayer;

  factory Summary.fromJson(Json j) => Summary(
    totalHits: asInt(j['total_hits']) ?? 0,
    strokeCounts: _counts(j['stroke_counts']),
    peakSpeedKmh: asDouble(j['peak_speed_kmh']),
    perPlayer: (j['per_player'] as Map? ?? const {}).map(
      (k, v) => MapEntry(k as String, PlayerSummary.fromJson(v as Json)),
    ),
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
