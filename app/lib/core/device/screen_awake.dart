import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen on while a live session runs (T12.6): a phone that locks mid-match
/// stops its camera, which ends the session.
abstract class ScreenAwake {
  const ScreenAwake();

  Future<void> keepOn(bool on);
}

class PlatformScreenAwake extends ScreenAwake {
  const PlatformScreenAwake();

  @override
  Future<void> keepOn(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } on Object catch (e) {
      // A platform without a wake lock just follows its own screen timeout.
      debugPrint('Could not ${on ? 'keep' : 'stop keeping'} the screen on: $e');
    }
  }
}

/// For tests: records the requests instead of calling the platform.
class FakeScreenAwake extends ScreenAwake {
  FakeScreenAwake();

  final requests = <bool>[];
  bool get on => requests.isNotEmpty && requests.last;

  @override
  Future<void> keepOn(bool on) async => requests.add(on);
}

final screenAwakeProvider = Provider<ScreenAwake>((ref) => const PlatformScreenAwake());
