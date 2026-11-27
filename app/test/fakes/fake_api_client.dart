import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/coach.dart';
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
             schemaVersion: '1.1',
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

  /// While set, uploads report half the bytes sent and wait for it (or a cancel).
  Completer<void>? uploadGate;

  /// Thrown by uploadVideo once the gate opens (any error, like a file that cannot be read).
  Object? uploadError;

  /// The cancel token of the last upload.
  CancelToken? uploadCancel;

  @override
  Future<VideoInfo> uploadVideo({
    required Stream<List<int>> stream,
    required int length,
    required String filename,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    calls.add('uploadVideo $filename $length');
    uploadCancel = cancelToken;
    onProgress?.call(length ~/ 2, length);
    final gate = uploadGate;
    if (gate != null) {
      await Future.any([gate.future, if (cancelToken != null) cancelToken.whenCancel]);
    }
    if (cancelToken?.isCancelled ?? false) throw ApiException('Cancelled');
    final error = uploadError ?? failWith;
    if (error != null) throw error;
    return videos['vid1']!;
  }

  List<({double x, double y})>? suggestedCorners;

  @override
  Future<List<({double x, double y})>?> suggestCourtCorners(String videoId, int frame) =>
      _answer('suggestCourtCorners $videoId $frame', () => suggestedCorners);

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
  Future<Job> getJob(String jobId) => _answer(
    'getJob $jobId',
    () => jobs.firstWhere(
      (j) => j.id == jobId,
      orElse: () => throw ApiException('job not found', statusCode: 404),
    ),
  );

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
    required String? winner,
    String? reason,
  }) => _answer('correctScore $jobId $rallyIndex $winner${reason == null ? '' : ' $reason'}', () {
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

  /// Score before each award, so undo can restore it.
  final _beforeAwards = <Score>[];

  @override
  Future<ScoreUpdate> awardPoint(
    String jobId, {
    required String winner,
    int? frame,
    String? reason,
  }) => _answer('awardPoint $jobId $winner $frame${reason == null ? '' : ' $reason'}', () {
    final old = record.score ?? const Score(near: 0, far: 0);
    _beforeAwards.add(old);
    final score = Score(
      near: old.near + (winner == 'near' ? 1 : 0),
      far: old.far + (winner == 'far' ? 1 : 0),
      corrections: [
        ...old.corrections,
        ScoreCorrection(
          rallyIndex: record.rallies.length,
          winnerAfter: winner,
          kind: 'award',
          frame: frame,
        ),
      ],
      server: winner,
    );
    record = record.copyWith(score: score);
    return ScoreUpdate(score: score, rallies: record.rallies);
  });

  @override
  Future<ScoreUpdate> concedeMatch(String jobId, {required String winner, int? frame}) =>
      _answer('concedeMatch $jobId $winner $frame', () {
        final old = record.score ?? const Score(near: 0, far: 0);
        _beforeAwards.add(old);
        final score = Score(
          near: old.near,
          far: old.far,
          bestOf: old.bestOf,
          game: old.game,
          games: old.games,
          gamesWon: old.gamesWon,
          matchWinner: winner,
          corrections: [
            ...old.corrections,
            ScoreCorrection(
              rallyIndex: record.rallies.length,
              winnerAfter: winner,
              kind: 'concede',
              frame: frame,
            ),
          ],
        );
        record = record.copyWith(score: score);
        return ScoreUpdate(score: score, rallies: record.rallies);
      });

  @override
  Future<ScoreUpdate> setGameService(
    String jobId, {
    required int game,
    required String serverId,
    required String receiverId,
  }) => _answer('setGameService $jobId $game $serverId $receiverId', () {
    final old = record.score ?? const Score(near: 0, far: 0);
    final score = Score(
      near: old.near,
      far: old.far,
      corrections: old.corrections,
      bestOf: old.bestOf,
      game: old.game,
      games: old.games,
      gamesWon: old.gamesWon,
      server: old.server,
      serviceCourt: old.serviceCourt,
      serverId: serverId,
      receiverId: receiverId,
    );
    record = record.copyWith(score: score);
    return ScoreUpdate(score: score, rallies: record.rallies);
  });

  @override
  Future<ScoreUpdate> undoScore(String jobId) => _answer('undoScore $jobId', () {
    final score = _beforeAwards.isEmpty
        ? (record.score ?? const Score(near: 0, far: 0))
        : _beforeAwards.removeLast();
    record = record.copyWith(score: score);
    return ScoreUpdate(score: score, rallies: record.rallies);
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

  @override
  Future<LineCallUpdate> overrideLineCall(String jobId, int callId, String call) =>
      _answer('overrideLineCall $jobId $callId $call', () {
        final calls = [
          for (final c in record.lineCalls)
            c.id == callId
                ? LineCall(
                    id: c.id,
                    rallyIndex: c.rallyIndex,
                    frame: c.frame,
                    timeS: c.timeS,
                    call: c.call,
                    landing: c.landing,
                    marginCm: c.marginCm,
                    confidence: c.confidence,
                    uncertain: c.uncertain,
                    overrideCall: call,
                  )
                : c,
        ];
        record = record.copyWith(lineCalls: calls);
        return LineCallUpdate(
          lineCalls: calls,
          score: record.score ?? const Score(near: 0, far: 0),
          rallies: record.rallies,
        );
      });

  /// Events the next chat() streams back (docs/API.md, POST /jobs/{id}/chat).
  List<Json> chatEvents = [
    {'type': 'delta', 'text': 'Your elbow was bent '},
    {'type': 'delta', 'text': 'on the smash [t=1.5s].'},
    {
      'type': 'done',
      'message': {
        'role': 'assistant',
        'text': 'Your elbow was bent on the smash [t=1.5s].',
        'at': '2026-11-05T09:20:00Z',
        'citations': [
          {'frame': 45, 'time_s': 1.5, 'hit_id': 2},
        ],
      },
      'disclaimer': 'Heuristic guidance',
    },
  ];

  @override
  Stream<Json> chat(String jobId, String message, {Json? personality}) async* {
    calls.add('chat $jobId $message');
    personalities.add(personality);
    final error = failWith;
    if (error != null) throw error;
    for (final e in chatEvents) {
      yield e;
    }
  }

  /// Events the next coachChat() streams back (POST /coach/chat, D42).
  List<Json> coachEvents = [
    {'type': 'delta', 'text': 'Land the split step as they hit '},
    {
      'type': 'done',
      'message': {
        'role': 'assistant',
        'text': 'Land the split step as they hit [kb:footwork#split-step].',
        'at': '2026-11-05T09:20:00Z',
        'citations': <Json>[],
      },
      'disclaimer': 'Heuristic guidance',
      'sources': [
        {
          'id': 'kb:footwork#split-step',
          'title': 'Footwork, base position and split step: Split step',
        },
      ],
    },
  ];

  /// The history each coachChat() call sent.
  final coachHistories = <List<Json>>[];

  /// The personality each chat() or coachChat() call sent (null for the Default coach).
  final personalities = <Json?>[];

  @override
  Stream<Json> coachChat(
    String message, {
    List<Json> history = const [],
    Json? personality,
  }) async* {
    calls.add('coachChat $message');
    coachHistories.add(history);
    personalities.add(personality);
    final error = failWith;
    if (error != null) throw error;
    for (final e in coachEvents) {
      yield e;
    }
  }

  /// What generatePersonality() returns (POST /coach/personality/generate, D53), or the
  /// error it throws.
  Json personalityDraft = {
    'name': 'Quiet Taskmaster',
    'description': 'Calm and strict about footwork, with dry humour.',
    'basePreset': 'stoic',
    'attributes': {
      'warmth': 45,
      'humor': 35,
      'sarcasm': 30,
      'formality': 60,
      'enthusiasm': 20,
      'directness': 85,
      'empathy': 55,
      'creativity': 45,
      'assertiveness': 85,
      'verbosity': 40,
    }, // dart format off
    'preferences': {'humorStyle': 'dry', 'emoji': 'none'},
    'instructions': 'Be strict about footwork and correct it first.',
    'notes': ["'Older' was read as calm and experienced."],
  };
  Object? personalityError;

  @override
  Future<Json> generatePersonality(String description, {String? basePreset}) async {
    calls.add('generatePersonality $description');
    final error = personalityError;
    if (error != null) throw error;
    return personalityDraft;
  }

  /// What coachReport() returns (GET /jobs/{id}/coach/report, D42).
  Json coachReportJson = {
    'summary': '3 hits in 1 rally. Top fix: bent hitting arm.',
    'strengths': ['Low serve contact (1 of 1 checked)'],
    'weaknesses': [
      {
        'title': 'Bent hitting arm at contact',
        'evidence': 'Near player: bent hitting arm on 1 of 1 smashes',
        'moments': [1.5],
        'drill': 'Throw and reach for a straight arm',
      },
    ],
    'drills': [
      {
        'name': 'Throw and reach for a straight arm',
        'purpose': 'Targets elbow_extension.',
        'how': 'Throw shuttles overhead from a side-on stance.',
        'kb_source': 'kb:drills#throw-and-reach-for-a-straight-arm',
      },
    ],
    'next_session_goals': ['Straighter arm on smashes'],
    'generated_by': 'gemini',
  };

  @override
  Future<CoachReport> coachReport(String jobId, {bool refresh = false}) async {
    calls.add('coachReport $jobId${refresh ? ' refresh' : ''}');
    final error = failWith;
    if (error != null) throw error;
    return CoachReport.fromJson(coachReportJson);
  }
}
