import 'json.dart';

enum JobStatus {
  queued,
  running,
  done,
  failed,
  cancelled;

  bool get isFinished => this == done || this == failed || this == cancelled;
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
  });

  final bool record;
  final bool video;
  final bool summary;
  final bool hitsCsv;

  factory JobOutputs.fromJson(Json? j) => j == null
      ? const JobOutputs()
      : JobOutputs(
          record: j['record'] as bool? ?? false,
          video: j['video'] as bool? ?? false,
          summary: j['summary'] as bool? ?? false,
          hitsCsv: j['hits_csv'] as bool? ?? false,
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
    this.finishedAt,
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
  final DateTime? finishedAt;
  final JobOutputs outputs;

  factory Job.fromJson(Json j) => Job(
    id: j['id'] as String,
    videoId: j['video_id'] as String,
    status: JobStatus.values.byName(j['status'] as String),
    queuePosition: asInt(j['queue_position']),
    currentStage: j['current_stage'] as String?,
    progress: asDouble(j['progress']) ?? 0,
    stages: asList(j['stages']).map(StageState.fromJson).toList(),
    error: j['error'] as String?,
    createdAt: asDate(j['created_at'])!,
    finishedAt: asDate(j['finished_at']),
    outputs: JobOutputs.fromJson(j['outputs'] as Json?),
  );
}

/// Options chosen on the upload screen and sent with POST /jobs.
class JobOptions {
  const JobOptions({required this.overlays, this.referee = false, this.calibrate = true});

  final Set<String> overlays;
  final bool referee;
  final bool calibrate;
}

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
