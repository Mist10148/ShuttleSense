import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/data/models/json.dart';
import 'package:shuttlesense_app/data/models/video_info.dart';

/// The golden record shared with the backend (backend/tests/fixtures/golden_record.json).
Json goldenRecordJson() =>
    jsonDecode(File('test/fixtures/golden_record.json').readAsStringSync()) as Json;

ClipRecord goldenRecord() => ClipRecord.fromJson(goldenRecordJson());

const kAllStages = [
  'io',
  'tracking',
  'pose',
  'court',
  'hits',
  'strokes',
  'feedback',
  'analytics',
  'referee',
  'render',
];

Json jobJson({
  String id = 'job1',
  String videoId = 'vid1',
  String status = 'done',
  double progress = 1,
  String? error,
  List<String> overlays = const ['trail', 'boxes'],
  bool referee = false,
  String createdAt = '2026-11-05T09:13:01Z',
}) => {
  'id': id,
  'video_id': videoId,
  'status': status,
  'queue_position': status == 'queued' ? 0 : null,
  'current_stage': status == 'running' ? 'pose' : null,
  'progress': progress,
  'stages': [
    for (final s in kAllStages)
      {'name': s, 'status': status == 'done' ? 'done' : 'pending', 'progress': 0.0},
  ],
  'error': error,
  'created_at': createdAt,
  'started_at': createdAt,
  'finished_at': status == 'done' ? createdAt : null,
  'outputs': {
    'record': status == 'done',
    'video': status == 'done',
    'summary': status == 'done',
    'hits_csv': status == 'done',
    'rallies_csv': status == 'done',
  },
  'overlays': overlays,
  'court_corners_px': null,
  'referee': referee,
};

Json videoJson({String id = 'vid1', String filename = 'rally01.mp4'}) => {
  'id': id,
  'filename': filename,
  'size_bytes': 1000,
  'fps': 30.0,
  'width': 1280,
  'height': 720,
  'num_frames': 60,
  'duration_s': 2.0,
  'created_at': '2026-11-05T09:12:00Z',
};

/// In-memory ApiClient for widget tests: canned responses and a log of calls.
class FakeApiClient extends ApiClient {
  FakeApiClient({
    Health? health,
    List<Job>? jobs,
    Map<String, VideoInfo>? videos,
    ClipRecord? record,
    this.failWith,
  }) : healthInfo =
           health ??
           const Health(
             version: '0.1.0',
             schemaVersion: '1.0',
             device: 'cpu',
             authRequired: false,
             stages: kAllStages,
           ),
       jobs = jobs ?? [Job.fromJson(jobJson())],
       videos = videos ?? {'vid1': VideoInfo.fromJson(videoJson())},
       record = record ?? goldenRecord(),
       super(const ServerConfig(baseUrl: 'http://fake:8000'), dio: Dio());

  final Health healthInfo;
  final List<Job> jobs;
  final Map<String, VideoInfo> videos;
  ClipRecord record;

  /// Called with the options of every createJob, for checks on what would be sent.
  void Function(JobOptions options)? onCreateJob;

  /// When set, every call throws this.
  ApiException? failWith;
  final List<String> calls = [];

  Future<T> _answer<T>(String call, T Function() value) async {
    calls.add(call);
    final error = failWith;
    if (error != null) throw error;
    return value();
  }

  @override
  Future<Health> health() => _answer('health', () => healthInfo);

  @override
  Future<VideoInfo> getVideo(String videoId) => _answer('getVideo $videoId', () {
    final v = videos[videoId];
    if (v == null) throw ApiException('video not found', statusCode: 404);
    return v;
  });

  @override
  Future<void> deleteVideo(String videoId) =>
      _answer('deleteVideo $videoId', () => videos.remove(videoId));

  @override
  Future<List<Job>> listJobs({int limit = 50}) => _answer('listJobs', () => List.of(jobs));

  @override
  Future<Job> getJob(String jobId) =>
      _answer('getJob $jobId', () => jobs.firstWhere((j) => j.id == jobId));

  @override
  Future<Job> createJob({
    required String videoId,
    required JobOptions options,
    List<({double x, double y})>? corners,
  }) => _answer('createJob $videoId ${options.overlays.join(',')}', () {
    onCreateJob?.call(options);
    final job = Job.fromJson(
      jobJson(id: 'job${jobs.length + 1}', videoId: videoId, status: 'queued', progress: 0),
    );
    jobs.add(job);
    return job;
  });

  @override
  Future<ClipRecord> getRecord(String jobId) => _answer('getRecord $jobId', () => record);

  @override
  Future<Job> render(String jobId, Set<String> overlays) =>
      _answer('render $jobId ${overlays.join(',')}', () => jobs.firstWhere((j) => j.id == jobId));

  @override
  Future<ScoreUpdate> correctScore(
    String jobId, {
    required int rallyIndex,
    required String winner,
  }) => _answer('correctScore $jobId $rallyIndex $winner', () {
    final after = ScorePair(near: winner == 'near' ? 1 : 0, far: winner == 'far' ? 1 : 0);
    final rallies = [
      for (final r in record.rallies)
        r.index == rallyIndex
            ? Rally(
                index: r.index,
                startFrame: r.startFrame,
                endFrame: r.endFrame,
                strokeCount: r.strokeCount,
                landing: r.landing,
                winner: winner,
                scoreAfter: after,
              )
            : r,
    ];
    final score = Score(near: after.near, far: after.far);
    record = record.copyWith(rallies: rallies, score: score);
    return ScoreUpdate(score: score, rallies: rallies);
  });

  @override
  Future<void> download(
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
  }) => _answer('download $url', () {
    onProgress?.call(10, 10);
    File(savePath).writeAsStringSync('data');
  });

  @override
  Future<void> deleteJob(String jobId) =>
      _answer('deleteJob $jobId', () => jobs.removeWhere((j) => j.id == jobId));
}
