import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/server_config.dart';
import '../api_client.dart';
import '../models/clip_record.dart';
import '../models/health.dart';
import '../models/job.dart';
import '../models/video_info.dart';

/// The client for the saved server. Screens use the providers below, never Dio directly.
final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(serverConfigProvider);
  if (config == null) throw StateError('No server configured');
  final api = ApiClient(config);
  ref.onDispose(api.close);
  return api;
});

/// Waits after failed polls: 2, 4, 8, 16, then 30 s; one more failure gives up.
const kPollBackoff = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 30),
];

/// Polls GET /jobs/{id} until the job finishes (docs/API.md, polling guidance): every 1 s
/// while running, 3 s while queued, backing off on network errors before reporting
/// "Lost connection" (the job keeps running on the server).
final jobProvider = StreamProvider.autoDispose.family<Job, String>((ref, jobId) async* {
  final api = ref.watch(apiClientProvider);
  // The loop must not outlive the screen, even while it is backing off.
  var alive = true;
  ref.onDispose(() => alive = false);
  var failures = 0;
  while (alive) {
    final Job job;
    try {
      job = await api.getJob(jobId);
      failures = 0;
    } on ApiException catch (e) {
      // Client errors (missing job, wrong token) will not fix themselves; anything else
      // (no answer, 5xx) may be a network blip or a restarting server.
      final status = e.statusCode;
      final clientError = status != null && status < 500;
      if (clientError || failures >= kPollBackoff.length) rethrow;
      await Future<void>.delayed(kPollBackoff[failures++]);
      continue;
    }
    yield job;
    if (job.status.isFinished) return;
    await Future<void>.delayed(
      job.status == JobStatus.queued ? const Duration(seconds: 3) : const Duration(seconds: 1),
    );
  }
});

final jobsListProvider = FutureProvider.autoDispose<List<Job>>(
  (ref) => ref.watch(apiClientProvider).listJobs(),
);

final videoProvider = FutureProvider.autoDispose.family<VideoInfo, String>(
  (ref, videoId) => ref.watch(apiClientProvider).getVideo(videoId),
);

final recordProvider = FutureProvider.autoDispose.family<ClipRecord, String>(
  (ref, jobId) => ref.watch(apiClientProvider).getRecord(jobId),
);

/// GET /health of the saved server: version, schema and installed stages.
final healthProvider = FutureProvider.autoDispose<Health>(
  (ref) => ref.watch(apiClientProvider).health(),
);
