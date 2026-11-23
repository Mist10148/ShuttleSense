import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/config/server_config.dart';
import 'models/clip_record.dart';
import 'models/coach.dart';
import 'models/health.dart';
import 'models/job.dart';
import 'models/json.dart';
import 'models/video_info.dart';

/// User-facing error from any API call.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  /// No answer from ShuttleSense itself: no response at all, or a gateway in front of it
  /// (the Cloudflare tunnel answers 502/530 once Colab has stopped).
  bool get unreachable =>
      statusCode == null ||
      const {502, 503, 504, 520, 521, 522, 523, 524, 530}.contains(statusCode);

  /// Worth asking again: unreachable, a server error, a request timeout or rate limiting.
  /// Other client errors (missing job, wrong token) will not fix themselves.
  bool get retryable => unreachable || statusCode! >= 500 || statusCode == 408 || statusCode == 429;

  @override
  String toString() => message;
}

/// The server's error text: FastAPI's `detail` string, or the first message of a 422
/// validation list. Null for bodies that are not ShuttleSense errors (e.g. a proxy's HTML).
String? errorDetail(Object? data) {
  if (data is! Map) return null;
  final detail = data['detail'];
  if (detail is String) return detail;
  if (detail is List && detail.isNotEmpty && detail.first is Map) {
    final msg = (detail.first as Map)['msg'];
    if (msg is String) return msg;
  }
  return null;
}

/// Typed client for every endpoint in docs/API.md.
class ApiClient {
  ApiClient(this.config, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: config.baseUrl,
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {
                if (config.token?.isNotEmpty ?? false) 'Authorization': 'Bearer ${config.token}',
              },
            ),
          );

  final ServerConfig config;
  final Dio _dio;

  Map<String, String> get authHeaders => {
    if (config.token?.isNotEmpty ?? false) 'Authorization': 'Bearer ${config.token}',
  };

  /// URL usable where headers cannot be set (web <video>, browser downloads).
  String urlWithToken(String path) {
    final token = config.token;
    final base = '${config.baseUrl}$path';
    return token == null || token.isEmpty ? base : '$base?token=${Uri.encodeQueryComponent(token)}';
  }

  /// Frees the connection pool once the client is replaced (server changed).
  void close() => _dio.close(force: true);

  Future<T> _call<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final message = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.connectionError => 'Cannot reach server at ${config.baseUrl}',
        DioExceptionType.sendTimeout ||
        DioExceptionType.receiveTimeout => 'The server took too long to answer',
        DioExceptionType.badCertificate => 'The server\'s HTTPS certificate is not trusted',
        DioExceptionType.cancel => 'Cancelled',
        _ when status == 401 => 'Wrong or missing access token',
        _ => errorDetail(e.response?.data) ?? _statusMessage(status),
      };
      throw ApiException(message, statusCode: status);
    } on FormatException {
      throw ApiException('Unexpected response from the server');
    } on TypeError {
      // fromJson met a field of the wrong type: not a ShuttleSense server, or a newer one.
      throw ApiException('Unexpected response from the server');
    }
  }

  static String _statusMessage(int? status) => switch (status) {
    413 => 'The video is larger than the server accepts',
    415 => 'Unsupported video type; use MP4, MOV or AVI',
    final s? when s >= 500 => 'Server error ($s). Check the server log.',
    final s? => 'Request failed ($s)',
    null => 'Request failed',
  };

  // Health -------------------------------------------------------------------

  Future<Health> health() => _call(() async {
    final res = await _dio.get<Json>('/health');
    return Health.fromJson(res.data!);
  });

  // Videos -------------------------------------------------------------------

  Future<VideoInfo> uploadVideo({
    required Stream<List<int>> stream,
    required int length,
    required String filename,
    void Function(int sent, int total)? onProgress,
    CancelToken? cancelToken,
  }) => _call(() async {
    final form = FormData.fromMap({
      'file': MultipartFile.fromStream(() => stream, length, filename: filename),
    });
    final res = await _dio.post<Json>(
      '/videos',
      data: form,
      onSendProgress: onProgress,
      cancelToken: cancelToken,
      options: Options(receiveTimeout: Duration.zero, sendTimeout: Duration.zero),
    );
    return VideoInfo.fromJson(res.data!);
  });

  Future<VideoInfo> getVideo(String videoId) => _call(() async {
    final res = await _dio.get<Json>('/videos/$videoId');
    return VideoInfo.fromJson(res.data!);
  });

  String sourceVideoUrl(String videoId) => urlWithToken('/videos/$videoId/source');

  Future<Json> practicePlayers(String videoId, int frame) => _call(
    () async => (await _dio.get<Json>(
      '/practice/videos/$videoId/players',
      queryParameters: {'frame': frame},
      options: Options(receiveTimeout: const Duration(minutes: 5)),
    )).data!,
  );

  Future<Json> startPractice(Json setup) =>
      _call(() async => (await _dio.post<Json>('/practice/sessions', data: setup)).data!);

  Future<Json> practiceStatus(String id) =>
      _call(() async => (await _dio.get<Json>('/practice/sessions/$id')).data!);

  Future<Json> resumePractice(String id, int frame, List<double> bbox) => _call(
    () async => (await _dio.post<Json>(
      '/practice/sessions/$id/selection',
      data: {'frame': frame, 'bbox': bbox},
    )).data!,
  );

  Future<Json> practiceResult(String id) => _call(
    () async => (await _dio.get<Json>(
      '/practice/sessions/$id/result',
      options: Options(receiveTimeout: const Duration(minutes: 5)),
    )).data!,
  );

  Future<Json> savePracticeEvents(String id, List<dynamic> events) => _call(
    () async =>
        (await _dio.put<Json>('/practice/sessions/$id/events', data: {'events': events})).data!,
  );

  String practiceVideoUrl(String id) => urlWithToken('/jobs/$id/video');

  Future<Json> startBackgroundWatch({
    required String videoId,
    required String court,
    required List<({double x, double y})> corners,
    bool focusedAnalysis = false,
  }) => _call(() async {
    final res = await _dio.post<Json>(
      '/watch/background',
      data: {
        'video_id': videoId,
        'court': court,
        if (focusedAnalysis) 'focused_analysis': true,
        if (corners.isNotEmpty)
          'corners': [
            for (final c in corners) [c.x, c.y],
          ],
      },
      options: Options(receiveTimeout: const Duration(minutes: 5)),
    );
    return res.data!;
  });

  Future<Json> backgroundWatchStatus(String jobId) =>
      _call(() async => (await _dio.get<Json>('/watch/background/$jobId')).data!);

  Future<Json> updateBackgroundWatch(String jobId, double seconds, {bool stop = false}) => _call(
    () async => (await _dio.post<Json>(
      '/watch/background/$jobId/${stop ? 'stop' : 'position'}',
      data: {'seconds': seconds},
    )).data!,
  );

  /// Suggest singles-reference corners on the selected source frame.
  Future<List<({double x, double y})>?> suggestCourtCorners(String videoId, int frame) =>
      _call(() async {
        final res = await _dio.post<Json>(
          '/videos/$videoId/court-corners',
          queryParameters: {'frame': frame},
        );
        final corners = res.data!['corners'] as List?;
        return corners
            ?.map((p) => (x: (p[0] as num).toDouble(), y: (p[1] as num).toDouble()))
            .toList();
      });

  Future<Json> suggestMatchType(String videoId, List<({double x, double y})> corners) =>
      _call(() async {
        final res = await _dio.post<Json>(
          '/videos/$videoId/match-type',
          data: {
            'corners': [
              for (final c in corners) [c.x, c.y],
            ],
          },
          options: Options(receiveTimeout: const Duration(minutes: 5)),
        );
        return res.data!;
      });

  /// Frame JPEG URL. The token goes in the query too, because web image requests cannot
  /// always send headers.
  String frameUrl(String videoId, int n, {int maxWidth = 1280}) {
    final token = config.token;
    final auth = token == null || token.isEmpty ? '' : '&token=${Uri.encodeQueryComponent(token)}';
    return '${config.baseUrl}/videos/$videoId/frames/$n?max_width=$maxWidth$auth';
  }

  Future<void> deleteVideo(String videoId) => _call(() => _dio.delete<void>('/videos/$videoId'));

  // Jobs ---------------------------------------------------------------------

  Future<Job> createJob({
    required String videoId,
    required JobOptions options,
    List<({double x, double y})>? corners,
  }) => _call(() async {
    final res = await _dio.post<Json>(
      '/jobs',
      data: {
        'video_id': videoId,
        'overlays': options.overlays.toList(),
        'referee': options.referee,
        if (options.startScore != null)
          'start_score': {'near': options.startScore!.near, 'far': options.startScore!.far},
        if (options.referee) ...options.match.toJson(),
        // Doubles tracks four players even without the referee layer (Phase 9).
        if (options.court == 'doubles') 'court': 'doubles',
        if (options.strokeModel != null) 'stroke_model': options.strokeModel,
        if (corners != null)
          'court_corners_px': [
            for (final c in corners) [c.x, c.y],
          ],
      },
    );
    return Job.fromJson(res.data!);
  });

  Future<List<Job>> listJobs({int limit = 50}) => _call(() async {
    final res = await _dio.get<List<dynamic>>('/jobs', queryParameters: {'limit': limit});
    return res.data!.cast<Json>().map(Job.fromJson).toList();
  });

  Future<Job> getJob(String jobId) => _call(() async {
    final res = await _dio.get<Json>('/jobs/$jobId');
    return Job.fromJson(res.data!);
  });

  Future<ClipRecord> getRecord(String jobId) => _call(() async {
    final res = await _dio.get<Json>('/jobs/$jobId/record');
    return ClipRecord.fromJson(res.data!);
  });

  String videoUrl(String jobId) => urlWithToken('/jobs/$jobId/video');

  String summaryUrl(String jobId) => urlWithToken('/jobs/$jobId/summary.json');

  String hitsCsvUrl(String jobId) => urlWithToken('/jobs/$jobId/hits.csv');

  String ralliesCsvUrl(String jobId) => urlWithToken('/jobs/$jobId/rallies.csv');

  /// Download an export to [savePath] (mobile share sheet, desktop save dialog).
  Future<void> download(
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
  }) => _call(() => _dio.download(url, savePath, onReceiveProgress: onProgress));

  /// Re-render the annotated video with other overlays (POST /jobs/{id}/render).
  Future<Job> render(String jobId, Set<String> overlays) => _call(() async {
    final res = await _dio.post<Json>('/jobs/$jobId/render', data: {'overlays': overlays.toList()});
    return Job.fromJson(res.data!);
  });

  /// Set a rally's winner; [winner] null makes it undecided again.
  Future<ScoreUpdate> correctScore(
    String jobId, {
    required int rallyIndex,
    required String? winner,
    String? reason,
  }) => _call(() async {
    final res = await _dio.patch<Json>(
      '/jobs/$jobId/score',
      data: {'rally_index': rallyIndex, 'winner': winner, 'reason': ?reason},
    );
    return ScoreUpdate.fromJson(res.data!);
  });

  /// A point for a rally the referee layer missed, counted from [frame] on (D21).
  Future<ScoreUpdate> awardPoint(
    String jobId, {
    required String winner,
    int? frame,
    String? reason,
  }) => _call(() async {
    final res = await _dio.post<Json>(
      '/jobs/$jobId/score/award',
      data: {'winner': winner, 'frame': frame, 'reason': ?reason},
    );
    return ScoreUpdate.fromJson(res.data!);
  });

  /// The other side retired: [winner] wins the match at [frame] (clip record 1.5, D33).
  Future<ScoreUpdate> concedeMatch(String jobId, {required String winner, int? frame}) =>
      _call(() async {
        final res = await _dio.post<Json>(
          '/jobs/$jobId/score/concede',
          data: {'winner': winner, 'frame': frame},
        );
        return ScoreUpdate.fromJson(res.data!);
      });

  /// Clip record 1.7: the players changed ends at [frame]; the score goes with them.
  Future<ScoreUpdate> swapEnds(String jobId, {int? frame}) => _call(() async {
    final res = await _dio.post<Json>('/jobs/$jobId/score/ends', data: {'frame': frame});
    return ScoreUpdate.fromJson(res.data!);
  });

  /// Doubles (D23): who serves and receives first in [game] (2 or 3).
  Future<ScoreUpdate> setGameService(
    String jobId, {
    required int game,
    required String serverId,
    required String receiverId,
  }) => _call(() async {
    final res = await _dio.post<Json>(
      '/jobs/$jobId/score/service',
      data: {'game': game, 'server_id': serverId, 'receiver_id': receiverId},
    );
    return ScoreUpdate.fromJson(res.data!);
  });

  /// Take back the newest correction or award.
  Future<ScoreUpdate> undoScore(String jobId) => _call(() async {
    final res = await _dio.post<Json>('/jobs/$jobId/score/undo');
    return ScoreUpdate.fromJson(res.data!);
  });

  /// F20: confirm (same call) or override an automated line call.
  Future<LineCallUpdate> overrideLineCall(String jobId, int callId, String call) => _call(() async {
    final res = await _dio.patch<Json>('/jobs/$jobId/line-calls/$callId', data: {'call': call});
    return LineCallUpdate.fromJson(res.data!);
  });

  Future<ClipRecord> savePracticeGoal(String jobId, PracticeGoal goal, {bool? completed}) =>
      _call(() async {
        final res = await _dio.put<Json>(
          '/jobs/$jobId/practice-goal',
          data: goal.toJson(done: completed),
        );
        return ClipRecord.fromJson(res.data!);
      });

  /// WS /live address for this server (ws:// or wss://, token as a query parameter).
  Uri liveUri() {
    final base = Uri.parse(config.baseUrl);
    final token = config.token;
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/live',
      queryParameters: token == null || token.isEmpty ? null : {'token': token},
    );
  }

  /// F22: ask the coach. Yields the server-sent events of docs/API.md (delta, done, error).
  Stream<Json> chat(String jobId, String message) =>
      _events('/jobs/$jobId/chat', {'message': message});

  /// D42: ask the coach a general or progress question, not about one job. [history] holds
  /// the earlier turns of this conversation ({role, text}); the server does not keep them.
  Stream<Json> coachChat(String message, {List<Json> history = const []}) =>
      _events('/coach/chat', {'message': message, 'history': history});

  /// D42: the AI coaching report of a finished job; [refresh] writes it again.
  Future<CoachReport> coachReport(String jobId, {bool refresh = false}) => _call(() async {
    final path = '/jobs/$jobId/coach/report';
    final res = refresh ? await _dio.post<Json>(path) : await _dio.get<Json>(path);
    return CoachReport.fromJson(res.data!);
  });

  /// POST [path] and yield its server-sent events (delta, done, error).
  Stream<Json> _events(String path, Json data) async* {
    final Response<ResponseBody> res;
    try {
      res = await _dio.post<ResponseBody>(
        path,
        data: data,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(minutes: 3),
        ),
      );
    } on DioException catch (e) {
      // The body of an error response is a stream too; read its detail.
      var detail = e.message;
      final body = e.response?.data;
      if (body is ResponseBody) {
        final text = await utf8.decodeStream(body.stream);
        try {
          detail = errorDetail(jsonDecode(text)) ?? detail;
        } on FormatException {
          detail = text;
        }
      }
      throw ApiException(
        detail ?? 'The coach is not available',
        statusCode: e.response?.statusCode,
      );
    }
    final lines = res.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    // Failures mid-answer become ApiException too, so the chat screen shows every one.
    try {
      await for (final line in lines) {
        if (!line.startsWith('data: ')) continue;
        final event = jsonDecode(line.substring(6));
        if (event is! Json) throw const FormatException('event is not an object');
        yield event;
      }
    } on DioException catch (e) {
      throw ApiException('The answer was interrupted: ${e.message ?? 'connection lost'}');
    } on FormatException {
      throw ApiException('The server sent an answer the app could not read');
    }
  }

  Future<void> deleteJob(String jobId) => _call(() => _dio.delete<void>('/jobs/$jobId'));
}
