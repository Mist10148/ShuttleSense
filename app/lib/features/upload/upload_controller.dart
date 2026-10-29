import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/server_config.dart';
import '../../data/models/job.dart';

/// Above this the app warns before uploading (the server's default limit is 1024 MB).
const kLargeUploadBytes = 1024 * 1024 * 1024;

/// Clips longer than this are rejected by the server (FR-1).
const kMaxDurationS = 300;

/// Options picked on the upload screen, read by the calibration screen. Remembered between
/// sessions so a team member does not re-pick overlays for every clip (T4.3).
class JobOptionsNotifier extends Notifier<JobOptions> {
  static const _overlaysKey = 'options.overlays';
  static const _calibrateKey = 'options.calibrate';
  static const _refereeKey = 'options.referee';

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
    );
  }

  Future<void> set(JobOptions options) async {
    // The referee layer and the court overlays need a calibrated court.
    final next = options.calibrate
        ? options
        : options.copyWith(referee: false, overlays: options.overlays.difference(kCourtOverlays));
    state = next;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList(_overlaysKey, next.overlays.toList());
    await prefs.setBool(_calibrateKey, next.calibrate);
    await prefs.setBool(_refereeKey, next.referee);
  }

  Future<void> toggleOverlay(String name, bool on) {
    final overlays = {...state.overlays};
    on ? overlays.add(name) : overlays.remove(name);
    return set(state.copyWith(overlays: overlays));
  }
}

final pendingJobOptionsProvider = NotifierProvider<JobOptionsNotifier, JobOptions>(
  JobOptionsNotifier.new,
);

/// Size label: "350.2 MB" or "1.20 GB".
String formatBytes(int bytes) {
  const mb = 1024 * 1024;
  if (bytes >= 1024 * mb) return '${(bytes / (1024 * mb)).toStringAsFixed(2)} GB';
  return '${(bytes / mb).toStringAsFixed(1)} MB';
}
