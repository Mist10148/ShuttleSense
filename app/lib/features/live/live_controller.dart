import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../data/models/clip_record.dart';
import '../../data/models/json.dart';
import '../../data/repositories/analysis_repository.dart';
import '../calibration/calibration_screen.dart' show Corner;
import 'frame_source.dart';
import 'live_socket.dart';

enum LivePhase {
  starting,
  ready,
  calibrating,
  connecting,
  live,
  reconnecting,
  stopping,
  saved,
  error,
}

/// A player box and keypoints in processing pixels, for the overlay.
typedef LivePlayer = ({List<double> bbox, List<List<double>> keypoints});

/// Everything the live screen shows. Lists grow during the session and are shared between
/// states, so a frame event costs no copying.
class LiveState {
  const LiveState({
    this.phase = LivePhase.starting,
    this.error,
    this.permissionDenied = false,
    this.cameraLabel = 'Camera',
    this.still,
    this.stillSize,
    this.corners,
    this.sessionId,
    this.size,
    this.courtCorners,
    this.frames = const [],
    this.trail = const [],
    this.players = const {},
    this.hits = const [],
    this.rallies = const [],
    this.lineCalls = const [],
    this.score,
    this.rallyState,
    this.rallyStartFrame,
    this.strokesInRally = 0,
    this.speedKmh,
    this.peakSpeedKmh,
    this.qualityLevel = 0,
    this.qualityReason,
    this.latencyMs,
    this.sentFrames = 0,
    this.stages = const {},
    this.savedJobId,
    this.fps = 30,
  });

  final LivePhase phase;
  final String? error;
  final bool permissionDenied;
  final String cameraLabel;

  /// Calibration still (JPEG) and its size; corners are in its pixels.
  final Uint8List? still;
  final ({int width, int height})? stillSize;
  final List<Corner>? corners;

  final String? sessionId;

  /// Processing size the server reports positions in.
  final ({int width, int height})? size;

  /// Court corners in processing pixels (null: no calibration).
  final List<CourtPoint>? courtCorners;
  final List<FrameInfo> frames;

  /// Recent shuttle positions (processing pixels), newest last.
  final List<({double x, double y})> trail;
  final Map<String, LivePlayer> players;
  final List<Hit> hits;
  final List<Rally> rallies;
  final List<LineCall> lineCalls;
  final Score? score;
  final String? rallyState;
  final int? rallyStartFrame;
  final int strokesInRally;
  final double? speedKmh;
  final double? peakSpeedKmh;

  /// 0 is full quality; 1 and 2 mean the server lowered resolution to keep up.
  final int qualityLevel;
  final String? qualityReason;
  final double? latencyMs;
  final int sentFrames;
  final Map<String, bool> stages;
  final String? savedJobId;
  final double fps;

  bool get reducedQuality => qualityLevel > 0;

  int get frameIndex => frames.isEmpty ? 0 : frames.length - 1;

  /// The session so far as a clip record, for the minimap and scoreboard widgets.
  ClipRecord get record => ClipRecord(
    schemaVersion: '1.1',
    clipId: sessionId ?? 'live',
    mode: 'live',
    fps: fps,
    width: size?.width ?? 0,
    height: size?.height ?? 0,
    numFrames: frames.length,
    courtCorners: courtCorners,
    frames: frames,
    hits: hits,
    rallies: rallies,
    lineCalls: lineCalls,
    score: score,
  );

  LiveState copyWith({
    LivePhase? phase,
    String? error,
    bool? permissionDenied,
    String? cameraLabel,
    Uint8List? still,
    ({int width, int height})? stillSize,
    List<Corner>? corners,
    String? sessionId,
    ({int width, int height})? size,
    List<CourtPoint>? courtCorners,
    List<({double x, double y})>? trail,
    Map<String, LivePlayer>? players,
    Score? score,
    String? rallyState,
    int? rallyStartFrame,
    bool clearRallyStart = false,
    int? strokesInRally,
    double? speedKmh,
    double? peakSpeedKmh,
    int? qualityLevel,
    String? qualityReason,
    double? latencyMs,
    int? sentFrames,
    Map<String, bool>? stages,
    String? savedJobId,
    double? fps,
  }) => LiveState(
    phase: phase ?? this.phase,
    error: error,
    permissionDenied: permissionDenied ?? this.permissionDenied,
    cameraLabel: cameraLabel ?? this.cameraLabel,
    still: still ?? this.still,
    stillSize: stillSize ?? this.stillSize,
    corners: corners ?? this.corners,
    sessionId: sessionId ?? this.sessionId,
    size: size ?? this.size,
    courtCorners: courtCorners ?? this.courtCorners,
    frames: frames,
    trail: trail ?? this.trail,
    players: players ?? this.players,
    hits: hits,
    rallies: rallies,
    lineCalls: lineCalls,
    score: score ?? this.score,
    rallyState: rallyState ?? this.rallyState,
    rallyStartFrame: clearRallyStart ? null : (rallyStartFrame ?? this.rallyStartFrame),
    strokesInRally: strokesInRally ?? this.strokesInRally,
    speedKmh: speedKmh,
    peakSpeedKmh: peakSpeedKmh ?? this.peakSpeedKmh,
    qualityLevel: qualityLevel ?? this.qualityLevel,
    qualityReason: qualityReason ?? this.qualityReason,
    latencyMs: latencyMs ?? this.latencyMs,
    sentFrames: sentFrames ?? this.sentFrames,
    stages: stages ?? this.stages,
    savedJobId: savedJobId ?? this.savedJobId,
    fps: fps ?? this.fps,
  );
}

/// Frames per second the app tries to send; the camera may deliver fewer.
const kLiveTargetFps = 15.0;

/// Resume attempts after the connection drops, with these waits in between.
const kReconnectDelays = [Duration(seconds: 1), Duration(seconds: 2), Duration(seconds: 4)];

/// A state whose growing lists can be added to (the const defaults cannot).
LiveState _fresh() => LiveState(
  frames: List<FrameInfo>.empty(growable: true),
  hits: List<Hit>.empty(growable: true),
  rallies: List<Rally>.empty(growable: true),
  lineCalls: List<LineCall>.empty(growable: true),
);

class LiveController extends AutoDisposeNotifier<LiveState> {
  FrameSource? _source;
  LiveSocket? _socket;
  StreamSubscription<Json>? _events;
  bool _streaming = false;
  bool _disposed = false;
  int _nextFrame = 0;
  Completer<String?>? _saved;
  Completer<Json>? _started;

  FrameSource? get source => _source;

  @override
  LiveState build() {
    ref.onDispose(() {
      _disposed = true;
      _streaming = false;
      _events?.cancel();
      _socket?.close();
      _source?.dispose();
    });
    Future.microtask(openCamera);
    return _fresh();
  }

  void _set(LiveState next) {
    if (!_disposed) state = next;
  }

  Future<void> openCamera() async {
    _set(_fresh());
    final source = ref.read(frameSourceFactoryProvider)();
    try {
      await source.start();
    } on CameraUnavailable catch (e) {
      await source.dispose();
      _set(
        state.copyWith(
          phase: LivePhase.error,
          error: e.message,
          permissionDenied: e.permissionDenied,
        ),
      );
      return;
    }
    if (_disposed) {
      await source.dispose();
      return;
    }
    _source = source;
    _set(state.copyWith(phase: LivePhase.ready, cameraLabel: source.label));
  }

  /// Take a still to tap the court corners on.
  Future<void> calibrate() async {
    final source = _source;
    if (source == null) return;
    try {
      final frame = await source.capture();
      _set(
        state.copyWith(
          phase: LivePhase.calibrating,
          still: frame.jpeg,
          stillSize: (width: frame.width, height: frame.height),
          corners: const [],
        ),
      );
    } on Exception catch (e) {
      _set(state.copyWith(error: 'Could not take a picture: $e'));
    }
  }

  void cancelCalibration() => _set(state.copyWith(phase: LivePhase.ready, corners: const []));

  /// Connect and start streaming; [corners] are in still pixels (null: no court).
  Future<void> start({List<Corner>? corners, ({int near, int far})? startScore}) async {
    final source = _source;
    if (source == null) return;
    _set(state.copyWith(phase: LivePhase.connecting, corners: corners ?? const []));
    final CapturedFrame first;
    try {
      first = await source.capture();
    } on Exception catch (e) {
      _set(state.copyWith(phase: LivePhase.error, error: 'Camera stopped: $e'));
      return;
    }
    final started = await _connect({
      'type': 'start',
      'fps': kLiveTargetFps,
      'width': first.width,
      'height': first.height,
      'corners': corners == null || corners.length != 4
          ? null
          : [
              for (final c in corners) [c.x, c.y],
            ],
      'start_score': startScore == null ? null : {'near': startScore.near, 'far': startScore.far},
      'court': 'singles',
    });
    if (started == null) return;
    _beginStreaming();
  }

  /// Open the socket, send [hello] and wait for `started`; null (and the error shown) if not.
  Future<Json?> _connect(Json hello) async {
    final api = ref.read(apiClientProvider);
    final socket = ref.read(liveSocketFactoryProvider)(api.liveUri());
    try {
      await socket.ready;
    } on Object {
      await socket.close();
      _set(
        state.copyWith(
          phase: LivePhase.error,
          error: 'Cannot reach the live server at ${api.config.baseUrl}',
        ),
      );
      return null;
    }
    // The old subscription may belong to a dropped socket; do not wait on its cleanup.
    unawaited(_events?.cancel());
    _socket = socket;
    _started = Completer<Json>();
    _events = socket.events.listen(_onEvent, onDone: _onClosed, onError: (_) => _onClosed());
    socket.sendJson(hello);
    try {
      final started = await _started!.future.timeout(const Duration(seconds: 15));
      final size = (width: asInt(started['width'])!, height: asInt(started['height'])!);
      _set(
        state.copyWith(
          phase: LivePhase.live,
          sessionId: started['session_id'] as String,
          size: size,
          courtCorners: (started['corners'] as List?)?.map((p) => asPoint(p)!).toList(),
          fps: asDouble(started['fps']),
          stages: (started['stages'] as Map? ?? const {}).map(
            (k, v) => MapEntry(k as String, v as bool),
          ),
        ),
      );
      return started;
    } on Exception catch (e) {
      if (state.phase != LivePhase.error) {
        _set(
          state.copyWith(
            phase: LivePhase.error,
            error: e is TimeoutException ? 'The live server did not answer' : '$e',
          ),
        );
      }
      await socket.close();
      return null;
    }
  }

  void _beginStreaming() {
    if (_streaming) return;
    _streaming = true;
    unawaited(_stream());
  }

  Future<void> _stream() async {
    final interval = Duration(microseconds: (1e6 / kLiveTargetFps).round());
    final clock = Stopwatch()..start();
    while (_streaming && !_disposed) {
      final due = interval * _nextFrame;
      if (clock.elapsed < due) await Future<void>.delayed(due - clock.elapsed);
      final source = _source, socket = _socket;
      if (source == null || socket == null || state.phase != LivePhase.live) {
        await Future<void>.delayed(interval);
        continue;
      }
      try {
        final frame = await source.capture();
        if (!_streaming || state.phase != LivePhase.live) continue;
        socket.sendFrame(
          _nextFrame++,
          DateTime.now().millisecondsSinceEpoch.toDouble(),
          frame.jpeg,
        );
        _set(state.copyWith(sentFrames: state.sentFrames + 1, speedKmh: state.speedKmh));
      } on Exception catch (e) {
        _streaming = false;
        _set(state.copyWith(phase: LivePhase.error, error: 'Camera stopped: $e'));
      }
    }
  }

  void _onEvent(Json e) {
    switch (e['type']) {
      case 'started':
        _started?.complete(e);
      case 'frame':
        _onFrame(e);
      case 'hit':
        state.hits.add(Hit.fromJson(e['hit'] as Json));
        _set(state.copyWith(speedKmh: state.speedKmh));
      case 'line_call':
        final call = LineCall.fromJson(e['line_call'] as Json);
        final i = state.lineCalls.indexWhere((c) => c.id == call.id);
        i < 0 ? state.lineCalls.add(call) : state.lineCalls[i] = call;
        _set(state.copyWith(speedKmh: state.speedKmh));
      case 'rally':
        if (e['state'] == 'in_play') {
          _set(
            state.copyWith(
              rallyState: 'in_play',
              rallyStartFrame: asInt(e['start_frame']),
              speedKmh: state.speedKmh,
            ),
          );
        } else {
          final rally = Rally.fromJson(e['rally'] as Json);
          final i = state.rallies.indexWhere((r) => r.index == rally.index);
          i < 0 ? state.rallies.add(rally) : state.rallies[i] = rally;
          _set(
            state.copyWith(
              rallyState: 'between_rallies',
              clearRallyStart: true,
              speedKmh: state.speedKmh,
            ),
          );
        }
      case 'score':
        final rallies = asList(e['rallies']).map(Rally.fromJson).toList();
        state.rallies
          ..clear()
          ..addAll(rallies);
        _set(state.copyWith(score: Score.fromJson(e['score'] as Json), speedKmh: state.speedKmh));
      case 'degraded':
        _set(
          state.copyWith(
            qualityLevel: asInt(e['level']) ?? 0,
            qualityReason: e['reason'] as String?,
            speedKmh: state.speedKmh,
          ),
        );
      case 'saved':
        _saved?.complete(e['job_id'] as String?);
      case 'error':
        _onServerError(e);
    }
  }

  void _onFrame(Json e) {
    final court = e['court'] as Json?;
    final speed = asDouble(e['speed_kmh']);
    final frame = asInt(e['frame'])!;
    // A frame event can repeat after a resume; keep one entry per frame index.
    if (frame >= state.frames.length) {
      state.frames.add(
        FrameInfo(
          frame: frame,
          nearPos: asPoint(court?['near']),
          farPos: asPoint(court?['far']),
          shuttlePos: asPoint(court?['shuttle']),
          shuttleSpeedKmh: speed,
          rallyState: e['rally_state'] as String?,
        ),
      );
    }
    final shuttle = e['shuttle'] as Json?;
    var trail = state.trail;
    if (shuttle != null && shuttle['visible'] == 1) {
      trail = [...trail, (x: asDouble(shuttle['x'])!, y: asDouble(shuttle['y'])!)];
      if (trail.length > 12) trail = trail.sublist(trail.length - 12);
    } else if (trail.isNotEmpty && e['skipped'] != true) {
      trail = trail.sublist(1);
    }
    final players = <String, LivePlayer>{};
    for (final side in ['near', 'far']) {
      final p = (e['players'] as Json?)?[side] as Json?;
      if (p == null) continue;
      players[side] = (
        bbox: [for (final v in p['bbox'] as List) (v as num).toDouble()],
        keypoints: [
          for (final k in p['keypoints'] as List)
            [for (final v in k as List) (v as num).toDouble()],
        ],
      );
    }
    final peak = state.peakSpeedKmh;
    _set(
      state.copyWith(
        trail: trail,
        players: players,
        speedKmh: speed,
        peakSpeedKmh: speed != null && (peak == null || speed > peak) ? speed : peak,
        rallyState: e['rally_state'] as String?,
        strokesInRally: asInt(e['strokes_in_rally']),
        latencyMs: asDouble(e['latency_ms']),
      ),
    );
  }

  void _onServerError(Json e) {
    final code = e['code'] as String?;
    final message = switch (code) {
      'busy' => 'The server is busy with a job or another live session. Try again when it is done.',
      'unauthorized' => 'Wrong or missing access token',
      'not_found' when state.phase == LivePhase.reconnecting =>
        'The session was lost. It was saved to History if any frames arrived.',
      _ => e['detail'] as String? ?? 'Live error',
    };
    // Frame-level problems are not fatal; the rest end the session.
    if (code == 'bad_frame' || code == 'bad_message' || code == 'not_found' && _started == null) {
      return;
    }
    _streaming = false;
    if (_started?.isCompleted == false) _started!.completeError(ApiException(message));
    _set(state.copyWith(phase: LivePhase.error, error: message));
  }

  /// The socket closed: resume if it dropped mid-session.
  void _onClosed() {
    if (_disposed || state.phase != LivePhase.live) return;
    unawaited(_reconnect());
  }

  Future<void> _reconnect() async {
    _set(state.copyWith(phase: LivePhase.reconnecting));
    for (final wait in kReconnectDelays) {
      await Future<void>.delayed(wait);
      if (_disposed || state.phase != LivePhase.reconnecting) return;
      final started = await _connect({'type': 'resume', 'session_id': state.sessionId});
      if (started != null) return;
      if (state.phase == LivePhase.error &&
          state.error?.startsWith('The session was lost') == true) {
        return;
      }
      _set(state.copyWith(phase: LivePhase.reconnecting));
    }
    _streaming = false;
    _set(
      state.copyWith(
        phase: LivePhase.error,
        error:
            'Lost the connection to the server. The session is saved to History if it '
            'cannot be resumed within a minute.',
      ),
    );
  }

  void overrideCall(int lineCallId, String call) =>
      _socket?.sendJson({'type': 'override', 'line_call_id': lineCallId, 'call': call});

  Future<void> correct(int rallyIndex, String winner) async =>
      _socket?.sendJson({'type': 'correct', 'rally_index': rallyIndex, 'winner': winner});

  /// Stop streaming and wait for the server to save the session.
  Future<void> stop() async {
    final socket = _socket;
    if (socket == null) return;
    _streaming = false;
    _set(state.copyWith(phase: LivePhase.stopping));
    _saved = Completer<String?>();
    socket.sendJson({'type': 'stop'});
    try {
      final jobId = await _saved!.future.timeout(const Duration(seconds: 30));
      _set(state.copyWith(phase: LivePhase.saved, savedJobId: jobId));
    } on TimeoutException {
      _set(state.copyWith(phase: LivePhase.error, error: 'The server did not confirm the save'));
    }
    await socket.close();
    _socket = null;
  }
}

final liveControllerProvider = AutoDisposeNotifierProvider<LiveController, LiveState>(
  LiveController.new,
);
