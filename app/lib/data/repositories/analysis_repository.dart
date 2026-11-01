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
      // No answer, 5xx, 408 or 429 may be a network blip or a restarting server; other
      // client errors (missing job, wrong token) will not fix themselves.
      if (!e.retryable || failures >= kPollBackoff.length) rethrow;
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

/// How often the saved server is checked again while a screen shows it (offline banner).
const kHealthRecheck = Duration(seconds: 30);
const kOfflineRecheck = Duration(seconds: 10);

/// GET /health of the saved server: version, schema and installed stages. Checked again
/// every [kHealthRecheck] (sooner while unreachable), so the offline banner appears when the
/// server drops and goes away when it is back.
final healthProvider = FutureProvider.autoDispose<Health>((ref) async {
  final api = ref.watch(apiClientProvider);
  Timer? recheck;
  ref.onDispose(() => recheck?.cancel());
  try {
    final health = await api.health();
    recheck = Timer(kHealthRecheck, ref.invalidateSelf);
    return health;
  } on ApiException {
    recheck = Timer(kOfflineRecheck, ref.invalidateSelf);
    rethrow;
  }
});

/// False only when the server is known to predate live mode (clip record 1.0); while its
/// health is unknown the choice stays open and the live screen reports what it finds.
final liveAvailableProvider = Provider.autoDispose<bool>(
  (ref) => ref.watch(healthProvider).valueOrNull?.supportsLive ?? true,
);
