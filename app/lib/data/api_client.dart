import 'package:dio/dio.dart';

import '../core/config/server_config.dart';
import 'models/clip_record.dart';
import 'models/health.dart';
import 'models/job.dart';
import 'models/json.dart';
import 'models/video_info.dart';

/// User-facing error from any API call.
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
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

  Future<T> _call<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final data = e.response?.data;
      final detail = data is Map ? data['detail']?.toString() : null;
      final message = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.connectionError => 'Cannot reach server at ${config.baseUrl}',
        DioExceptionType.cancel => 'Cancelled',
        _ when status == 401 => 'Wrong or missing access token',
        _ => detail ?? e.message ?? 'Request failed',
      };
      throw ApiException(message, statusCode: status);
    }
  }

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

  String frameUrl(String videoId, int n, {int maxWidth = 1280}) =>
      '${config.baseUrl}/videos/$videoId/frames/$n?max_width=$maxWidth';

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

  Future<Score> correctScore(String jobId, {required int rallyIndex, required String winner}) =>
      _call(() async {
        final res = await _dio.patch<Json>(
          '/jobs/$jobId/score',
          data: {'rally_index': rallyIndex, 'winner': winner},
        );
        return Score.fromJson(res.data!);
      });

  Future<void> deleteJob(String jobId) => _call(() => _dio.delete<void>('/jobs/$jobId'));
}
