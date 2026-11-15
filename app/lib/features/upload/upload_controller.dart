import 'dart:async';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/config/server_config.dart';
import '../../data/api_client.dart';
import '../../data/models/job.dart';
import '../../data/models/match_setup.dart';
import '../../data/repositories/analysis_repository.dart';

/// Above this the app warns before uploading (the server's default limit is 1024 MB).
const kLargeUploadBytes = 1024 * 1024 * 1024;

/// Clips longer than this are rejected by the server (FR-1).
const kMaxDurationS = 600;

/// Browsers get a lower cap: Dio's web adapter holds the whole request body in memory before
/// sending it, so a file near the server limit can crash the tab.
const kWebMaxUploadBytes = 512 * 1024 * 1024;

/// Why a picked file cannot be uploaded, or null if it can. [size] is null when the platform
/// could not tell the file size, which the multipart upload needs.
String? uploadSizeProblem(int? size, {required bool web}) {
  if (size == null) {
    return 'Could not read the size of this file. Copy it to the device and try again.';
  }
  if (size == 0) return 'This file is empty.';
  if (web && size > kWebMaxUploadBytes) {
    return 'The browser version uploads at most ${formatBytes(kWebMaxUploadBytes)}. Trim the '
        'clip to the rally, or use the Android or Windows app for larger files.';
  }
  return null;
}

/// Options picked on the upload screen, read by the calibration screen. Remembered between
/// sessions so a team member does not re-pick overlays for every clip (T4.3).
class JobOptionsNotifier extends Notifier<JobOptions> {
  static const _overlaysKey = 'options.overlays';
  static const _calibrateKey = 'options.calibrate';
  static const _refereeKey = 'options.referee';
  static const _bestOfKey = 'options.best_of';
  static const _firstServerKey = 'options.first_server';
  static const _courtKey = 'options.court';
  static const _firstServerIdKey = 'options.first_server_id';
  static const _firstReceiverIdKey = 'options.first_receiver_id';
  static const _strokeModelKey = 'options.stroke_model';

  @override
  JobOptions build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final overlays = prefs.getStringList(_overlaysKey);
    return JobOptions(
      overlays: overlays == null
          ? kOverlays.keys.toSet()
          : overlays.where(kOverlays.containsKey).toSet(),
      calibrate: prefs.getBool(_calibrateKey) ?? true,
      referee: prefs.getBool(_refereeKey) ?? false,
      bestOf: prefs.getInt(_bestOfKey) == 3 ? 3 : 1,
      firstServer: prefs.getString(_firstServerKey),
      court: prefs.getString(_courtKey) == 'doubles' ? 'doubles' : 'singles',
      firstServerId: prefs.getString(_firstServerIdKey),
      firstReceiverId: prefs.getString(_firstReceiverIdKey),
      strokeModel: switch (prefs.getString(_strokeModelKey)) {
        final String m when kStrokeModels.containsKey(m) => m,
        _ => kStrokeModels.keys.first,
      },
    );
  }

  Future<void> set(JobOptions options) async {
    // The referee layer needs a calibrated court. Court overlays stay remembered while
    // calibration is off (greyed out, and left out by JobOptions.submittable), so turning it
    // back on restores them.
    final next = options.calibrate ? options : options.copyWith(referee: false);
    state = next;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList(_overlaysKey, next.overlays.toList());
    await prefs.setBool(_calibrateKey, next.calibrate);
    await prefs.setBool(_refereeKey, next.referee);
  }

  /// Remembered: a team usually records the same kind of match.
  Future<void> setMatch(MatchSetup match) async {
    state = state.withMatch(match);
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setInt(_bestOfKey, match.bestOf);
    await prefs.setString(_courtKey, match.court);
    for (final (key, value) in [
      (_firstServerKey, match.firstServer),
      (_firstServerIdKey, match.firstServerId),
      (_firstReceiverIdKey, match.firstReceiverId),
    ]) {
      value == null ? await prefs.remove(key) : await prefs.setString(key, value);
    }
  }

  /// Remembered, and shared by upload and live: a team compares models on its own footage.
  Future<void> setStrokeModel(String model) async {
    if (!kStrokeModels.containsKey(model)) return;
    state = state.withStrokeModel(model);
    await ref.read(sharedPreferencesProvider).setString(_strokeModelKey, model);
  }

  /// For a clip that begins mid-game; not remembered, it belongs to one clip.
  void setStartScore(({int near, int far})? score) => state = state.withStartScore(score);

  Future<void> toggleOverlay(String name, bool on) {
    final overlays = {...state.overlays};
    on ? overlays.add(name) : overlays.remove(name);
    return set(state.copyWith(overlays: overlays));
  }
}

final pendingJobOptionsProvider = NotifierProvider<JobOptionsNotifier, JobOptions>(
  JobOptionsNotifier.new,
);

/// Length of a local clip in seconds, or null when it cannot be read here (web, content
/// URIs, unknown codecs). Only used to warn before uploading; the server checks it anyway.
typedef DurationProbe = Future<double?> Function(PlatformFile file);

Future<double?> probeDuration(PlatformFile file) async {
  final path = file.path;
  if (kIsWeb || path == null) return null;
  Player? player;
  try {
    player = Player();
    await player.open(Media(Uri.file(path).toString()), play: false);
    final d = await player.stream.duration
        .firstWhere((d) => d > Duration.zero)
        .timeout(const Duration(seconds: 3));
    return d.inMilliseconds / 1000;
  } on Object {
    return null;
  } finally {
    if (player != null) unawaited(player.dispose());
  }
}

final durationProbeProvider = Provider<DurationProbe>((ref) => probeDuration);

/// The picked file and the upload in flight (T4.2). The screen only renders this.
@immutable
class UploadState {
  const UploadState({
    this.file,
    this.size = 0,
    this.durationS,
    this.sent = 0,
    this.progress,
    this.error,
  });

  final PlatformFile? file;
  final int size;

  /// Length of the picked clip when the device could read it.
  final double? durationS;
  final int sent;

  /// 0..1 while uploading, else null.
  final double? progress;
  final String? error;

  bool get uploading => progress != null;
  bool get tooLong => durationS != null && durationS! > kMaxDurationS;
  bool get large => size > kLargeUploadBytes;

  UploadState copyWith({int? sent, double? progress, String? error}) => UploadState(
    file: file,
    size: size,
    durationS: durationS,
    sent: sent ?? this.sent,
    progress: progress,
    error: error,
  );
}

class UploadNotifier extends Notifier<UploadState> {
  CancelToken? _cancel;
  var _disposed = false;

  @override
  UploadState build() {
    ref.onDispose(() {
      _disposed = true;
      _cancel?.cancel();
    });
    return const UploadState();
  }

  void _set(UploadState next) {
    if (!_disposed) state = next;
  }

  /// Accept a picked file, or explain why it cannot be uploaded.
  Future<void> choose(PlatformFile file, {required bool web}) async {
    final size = await file.length();
    final problem = uploadSizeProblem(size, web: web);
    if (problem != null) {
      _set(UploadState(error: problem));
      return;
    }
    _set(UploadState(file: file, size: size!));
    ref.read(pendingJobOptionsProvider.notifier).setStartScore(null); // a new clip
    final duration = await ref.read(durationProbeProvider)(file);
    if (!_disposed && identical(state.file, file) && duration != null) {
      _set(UploadState(file: file, size: size, durationS: duration));
    }
  }

  /// Upload the picked file, then start the job unless calibration comes first. Null when
  /// the upload was cancelled or failed (the file is kept for a retry, [UploadState.error]
  /// says why).
  Future<({String videoId, Job? job})?> upload() async {
    final file = state.file;
    if (file == null || state.uploading) return null;
    final api = ref.read(apiClientProvider);
    final options = ref
        .read(pendingJobOptionsProvider)
        .submittable(ref.read(healthProvider).valueOrNull);
    final cancel = _cancel = CancelToken();
    _set(state.copyWith(progress: 0, sent: 0));
    try {
      final video = await api.uploadVideo(
        stream: file.readAsByteStream(),
        length: state.size,
        filename: file.name,
        cancelToken: cancel,
        onProgress: (sent, total) {
          if (total > 0 && !cancel.isCancelled) {
            _set(state.copyWith(sent: sent, progress: sent / total));
          }
        },
      );
      if (cancel.isCancelled) return null;
      final job = options.calibrate
          ? null
          : await api.createJob(videoId: video.id, options: options);
      _set(const UploadState());
      return (videoId: video.id, job: job);
    } on ApiException catch (e) {
      // A cancel the user asked for is not an error.
      _set(state.copyWith(error: cancel.isCancelled ? null : e.message));
      return null;
    } on Object catch (_) {
      // Anything else (say the file could not be read) must not leave the screen stuck
      // in "uploading": clear the progress and keep the file for a retry.
      _set(state.copyWith(error: cancel.isCancelled ? null : 'The upload failed. Try again.'));
      return null;
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  /// Stop the upload in flight; [upload] then clears the progress and keeps the file for a
  /// retry. Safe to call while the screen is being disposed (no state change here).
  void cancel() => _cancel?.cancel();
}

final uploadProvider = NotifierProvider<UploadNotifier, UploadState>(UploadNotifier.new);

/// Size label: "350.2 MB" or "1.20 GB".
String formatBytes(int bytes) {
  const mb = 1024 * 1024;
  if (bytes >= 1024 * mb) return '${(bytes / (1024 * mb)).toStringAsFixed(2)} GB';
  return '${(bytes / mb).toStringAsFixed(1)} MB';
}
