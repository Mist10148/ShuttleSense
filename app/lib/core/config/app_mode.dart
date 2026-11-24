import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'server_config.dart';

/// Upload a clip (offline) or go live with a camera (F18).
enum AppMode { upload, live, watch, practice }

/// The last mode the user picked; saved on the device. Upload until one is picked.
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
