import 'health.dart';
import 'json.dart';

enum JobStatus {
  queued,
  running,
  done,
  failed,
  cancelled;

  bool get isFinished => this == done || this == failed || this == cancelled;

  /// Unknown values (a newer server) count as running, so polling carries on.
  static JobStatus parse(String value) => values.asNameMap()[value] ?? JobStatus.running;
}

class StageState {
  const StageState({required this.name, required this.status, required this.progress});

  final String name;

  /// pending, running, done, skipped or failed.
  final String status;
  final double progress;

  factory StageState.fromJson(Json j) => StageState(
    name: j['name'] as String,
    status: j['status'] as String,
    progress: asDouble(j['progress']) ?? 0,
  );
}

class JobOutputs {
  const JobOutputs({
    this.record = false,
    this.video = false,
    this.summary = false,
    this.hitsCsv = false,
    this.ralliesCsv = false,
  });

  final bool record;
  final bool video;
  final bool summary;
  final bool hitsCsv;
  final bool ralliesCsv;

  factory JobOutputs.fromJson(Json? j) => j == null
      ? const JobOutputs()
      : JobOutputs(
          record: j['record'] as bool? ?? false,
          video: j['video'] as bool? ?? false,
          summary: j['summary'] as bool? ?? false,
          hitsCsv: j['hits_csv'] as bool? ?? false,
          ralliesCsv: j['rallies_csv'] as bool? ?? false,
        );
}

/// GET /jobs/{id} (docs/API.md).
class Job {
  const Job({
    required this.id,
    required this.videoId,
    required this.status,
    required this.progress,
    required this.stages,
    required this.outputs,
    required this.createdAt,
    this.queuePosition,
    this.currentStage,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.overlays = const [],
    this.courtCorners,
    this.referee = false,
    this.startScore,
    this.mode = 'upload',
  });

  final String id;
  final String videoId;
  final JobStatus status;
  final int? queuePosition;
  final String? currentStage;
  final double progress;
  final List<StageState> stages;
  final String? error;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final JobOutputs outputs;

  /// Options the job was created with (for retry and re-render).
  final List<String> overlays;
  final List<({double x, double y})>? courtCorners;
  final bool referee;
  final ({int near, int far})? startScore;

  /// upload, or live for a saved live session.
  final String mode;

  bool get isLive => mode == 'live';

  /// Time spent running so far (or in total once finished).
  Duration? elapsed([DateTime? now]) {
    final start = startedAt;
    if (start == null) return null;
    final spent = (finishedAt ?? now ?? DateTime.now().toUtc()).difference(start);
    // The device clock may be behind the server's.
    return spent.isNegative ? Duration.zero : spent;
  }

  /// Rough remaining time from progress and elapsed time; null early on.
  Duration? eta([DateTime? now]) {
    final spent = elapsed(now);
    if (spent == null || progress < 0.05 || progress >= 1) return null;
    return spent * ((1 - progress) / progress);
  }

  JobOptions get options => JobOptions(
    overlays: overlays.toSet(),
    referee: referee,
    calibrate: courtCorners != null,
    startScore: startScore,
  );

  factory Job.fromJson(Json j) => Job(
    id: j['id'] as String,
    videoId: j['video_id'] as String,
    status: JobStatus.parse(j['status'] as String),
    queuePosition: asInt(j['queue_position']),
    currentStage: j['current_stage'] as String?,
    progress: asDouble(j['progress']) ?? 0,
    stages: asList(j['stages']).map(StageState.fromJson).toList(),
    error: j['error'] as String?,
    createdAt: asDate(j['created_at'])!,
    startedAt: asDate(j['started_at']),
    finishedAt: asDate(j['finished_at']),
    outputs: JobOutputs.fromJson(j['outputs'] as Json?),
    overlays: (j['overlays'] as List<dynamic>? ?? const []).cast<String>(),
    courtCorners: (j['court_corners_px'] as List<dynamic>?)?.map((p) => asPoint(p)!).toList(),
    referee: j['referee'] as bool? ?? false,
    startScore: switch (j['start_score']) {
      final Json s => (near: asInt(s['near']) ?? 0, far: asInt(s['far']) ?? 0),
      _ => null,
    },
    mode: j['mode'] as String? ?? 'upload',
  );
}

/// Options chosen on the upload screen and sent with POST /jobs.
class JobOptions {
  const JobOptions({
    required this.overlays,
    this.referee = false,
    this.calibrate = true,
    this.startScore,
  });

  final Set<String> overlays;
  final bool referee;
  final bool calibrate;

  /// For clips that start mid-game (P3 referee).
  final ({int near, int far})? startScore;

  JobOptions copyWith({Set<String>? overlays, bool? referee, bool? calibrate}) => JobOptions(
    overlays: overlays ?? this.overlays,
    referee: referee ?? this.referee,
    calibrate: calibrate ?? this.calibrate,
    startScore: startScore,
  );

  JobOptions withStartScore(({int near, int far})? score) =>
      JobOptions(overlays: overlays, referee: referee, calibrate: calibrate, startScore: score);

  /// What to send to the server: no referee without calibration, no start score without the
  /// referee, and only the overlays that can be drawn (greyed-out chips keep their remembered
  /// choice but are not requested).
  JobOptions submittable(Health? health) {
    final base = calibrate && referee ? this : copyWith(referee: false).withStartScore(null);
    return base.copyWith(
      overlays: {
        for (final o in base.overlays)
          if (overlayDisabledReason(o, base, health) == null) o,
      },
    );
  }
}

/// Why an overlay cannot be chosen, or null when it can (T4.3, T5.12).
String? overlayDisabledReason(String overlay, JobOptions options, Health? health) {
  if (!options.calibrate && kCourtOverlays.contains(overlay)) return 'Needs court calibration';
  if (overlay == 'score' && !options.referee) return 'Needs the referee layer';
  if (health != null && !health.supportsOverlay(overlay, kOverlayStage)) {
    return 'Not installed on this server';
  }
  return null;
}

/// Overlays that need court calibration (court geometry or court-plane positions).
const kCourtOverlays = {'court', 'minimap', 'speed', 'score'};

/// The pipeline stage that produces each overlay (GET /health "stages").
const kOverlayStage = <String, String>{
  'trail': 'tracking',
  'pose': 'pose',
  'boxes': 'pose',
  'hits': 'hits',
  'strokes': 'strokes',
  'court': 'court',
  'minimap': 'analytics',
  'speed': 'analytics',
  'score': 'referee',
};

/// Overlay names accepted by the backend (backend/shuttlesense/render/overlays.py).
const kOverlays = <String, String>{
  'trail': 'Shuttle trail',
  'pose': 'Skeletons',
  'boxes': 'Player boxes',
  'hits': 'Hit markers',
  'strokes': 'Stroke labels',
  'court': 'Court outline',
  'minimap': 'Minimap',
  'speed': 'Speed',
  'score': 'Scoreboard',
};
