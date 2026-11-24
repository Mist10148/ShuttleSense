import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_config.dart';

/// The legacy upload mode remains readable from saved preferences.
enum AppMode { upload, live, watch, practice }

/// Gates the legacy Upload Clip screen and its setup route without removing them.
const uploadClipEnabled = false;

/// The last mode the user picked. The router handles an unavailable or unset mode.
class AppModeNotifier extends Notifier<AppMode> {
  static const _key = 'ui.mode';

  @override
  AppMode build() {
    final saved = ref.read(sharedPreferencesProvider).getString(_key);
    return AppMode.values.asNameMap()[saved] ?? AppMode.upload;
  }

  Future<void> set(AppMode mode) async {
    state = mode;
    await ref.read(sharedPreferencesProvider).setString(_key, mode.name);
  }
}

final appModeProvider = NotifierProvider<AppModeNotifier, AppMode>(AppModeNotifier.new);

/// Bumped to start a fresh AI Coach screen (a new video). The Analyze tab keeps its screen
/// alive, so without this choosing AI Coach again would show the last session.
class PracticeSessionNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void next() => state++;
}

final practiceSessionProvider = NotifierProvider<PracticeSessionNotifier, int>(
  PracticeSessionNotifier.new,
);
