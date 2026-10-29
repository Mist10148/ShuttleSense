import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/server_config.dart';
import '../api_client.dart';
import '../models/clip_record.dart';
import '../models/job.dart';
import '../models/video_info.dart';

/// The client for the saved server. Screens use the providers below, never Dio directly.
final apiClientProvider = Provider<ApiClient>((ref) {
  final config = ref.watch(serverConfigProvider);
  if (config == null) throw StateError('No server configured');
  return ApiClient(config);
});

/// Polls GET /jobs/{id} until the job finishes (docs/API.md, polling guidance).
final jobProvider = StreamProvider.autoDispose.family<Job, String>((ref, jobId) async* {
  final api = ref.watch(apiClientProvider);
  while (true) {
    final job = await api.getJob(jobId);
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

/// Options picked on the upload screen, read by the calibration screen.
final pendingJobOptionsProvider = StateProvider<JobOptions>(
  (ref) => JobOptions(overlays: kOverlays.keys.toSet()),
);
