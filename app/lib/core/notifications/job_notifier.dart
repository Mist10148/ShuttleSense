import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/server_config.dart';

/// Tells the user a job has finished while the app is in the background (T4.4, T10.4).
abstract class JobNotifier {
  /// Ask for permission while the app is in front (Android 13+); safe to call often.
  /// False when notifications cannot be shown.
  Future<bool> prepare();

  Future<void> jobFinished({required String jobId, required bool ok});
}

/// Web, tests and platforms without notifications.
class NoopJobNotifier implements JobNotifier {
  const NoopJobNotifier();

  @override
  Future<bool> prepare() async => false;

  @override
  Future<void> jobFinished({required String jobId, required bool ok}) async {}
}

/// A system notification through flutter_local_notifications. Any failure (no permission,
/// an unsupported desktop) is swallowed: the processing screen still shows the result.
class LocalJobNotifier implements JobNotifier {
  LocalJobNotifier([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  Future<bool>? _ready;

  static const _settings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    ),
    windows: WindowsInitializationSettings(
      appName: 'ShuttleSense',
      appUserModelId: 'ShuttleSense.App',
      guid: '5b6e2f0c-7d3a-4c1e-9a54-2f1c8d7e3b90',
    ),
  );

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'jobs',
      'Finished analyses',
      channelDescription: 'When a clip has finished processing',
    ),
    iOS: DarwinNotificationDetails(),
  );

  Future<bool> _init() async {
    try {
      final ok = await _plugin.initialize(settings: _settings) ?? false;
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true);
      return ok;
    } on Object catch (e) {
      debugPrint('Notifications unavailable: $e');
      return false;
    }
  }

  @override
  Future<bool> prepare() => _ready ??= _init();

  @override
  Future<void> jobFinished({required String jobId, required bool ok}) async {
    if (!await prepare()) return;
    try {
      await _plugin.show(
        id: jobId.hashCode & 0x7fffffff,
        title: ok ? 'Analysis ready' : 'Analysis failed',
        body: ok
            ? 'Your clip has been analysed. Tap to open ShuttleSense.'
            : 'Open ShuttleSense to see why.',
        notificationDetails: _details,
        payload: jobId,
      );
    } on Object catch (e) {
      debugPrint('Could not show a notification: $e');
    }
  }
}

final jobNotifierProvider = Provider<JobNotifier>((ref) {
  final supported =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.windows);
  return supported ? LocalJobNotifier() : const NoopJobNotifier();
});

/// Whether to notify when a job finishes in the background; saved on the device, on by default.
class NotifyWhenDoneNotifier extends Notifier<bool> {
  static const _key = 'ui.notifyWhenDone';

  @override
  bool build() => ref.read(sharedPreferencesProvider).getBool(_key) ?? true;

  Future<void> set(bool on) async {
    state = on;
    await ref.read(sharedPreferencesProvider).setBool(_key, on);
  }
}

final notifyWhenDoneProvider = NotifierProvider<NotifyWhenDoneNotifier, bool>(
  NotifyWhenDoneNotifier.new,
);

/// True unless the app is visible and in front.
bool appInBackground() {
  final state = WidgetsBinding.instance.lifecycleState;
  return state != null && state != AppLifecycleState.resumed;
}

/// [appInBackground], replaceable in tests.
final appInBackgroundProvider = Provider<bool Function()>((ref) => appInBackground);
