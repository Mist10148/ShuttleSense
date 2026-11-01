import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Frames per second the app sends at most; a slower camera sets a lower rate.
const kLiveTargetFps = 15.0;

/// Resume attempts after the connection drops, with these waits in between. They span about
/// half a minute because after an abrupt drop the server only notices at its next ping and
/// refuses the resume (`not_found`) until then.
const kReconnectDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
];

/// The rate to announce after [captures] stills took [elapsed]: at most [kLiveTargetFps],
/// rounded down to 0.1 fps so the app never sends faster than it said.
double liveFps(Duration elapsed, int captures) {
  final seconds = elapsed.inMicroseconds / 1e6 / captures;
  final measured = seconds <= 0 ? kLiveTargetFps : 1 / seconds;
  return (measured.clamp(1.0, kLiveTargetFps) * 10).floorToDouble() / 10;
}

/// How long to wait for `started`: the server loads TrackNet and the pose model first.
const kStartTimeout = Duration(seconds: 90);

/// The server turned the start or resume down; [code] is its error code.
class _Refused implements Exception {
  _Refused(this.code, this.message);

  final String? code;
  final String message;

  @override
  String toString() => message;
}

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

  /// Bumped by [_teardown]; loops and reconnects of an older session stop when it changes.
  int _generation = 0;

  /// The rate frames are sent at: what the camera managed when the session started.
  double _fps = kLiveTargetFps;

  FrameSource? get source => _source;

  @override
  LiveState build() {
    ref.onDispose(() {
      _disposed = true;
      unawaited(_teardown());
    });
    Future.microtask(openCamera);
    return _fresh();
  }

  void _set(LiveState next) {
    if (!_disposed) state = next;
  }

  /// Ends whatever the previous attempt left running: the stream loop, a pending reconnect,
  /// the socket and the camera.
  Future<void> _teardown() async {
    _generation++;
    _streaming = false;
    _nextFrame = 0;
    _started = null;
    _saved = null;
    final events = _events, socket = _socket, source = _source;
    _events = null;
    _socket = null;
    _source = null;
    await events?.cancel();
    await socket?.close();
    await source?.dispose();
  }

  Future<void> openCamera() async {
    await _teardown();
    final generation = _generation;
    _set(_fresh());
    final source = ref.read(frameSourceFactoryProvider)();
    try {
      await source.start();
    } on Object catch (e) {
      await source.dispose();
      _set(
        state.copyWith(
          phase: LivePhase.error,
          error: e is CameraUnavailable ? e.message : 'Could not open the camera: $e',
          permissionDenied: e is CameraUnavailable && e.permissionDenied,
        ),
      );
      return;
    }
    if (_disposed || generation != _generation) {
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
      // Time a few captures: still captures are slower than video on most devices, and the
      // server times everything (the recording, speeds, the rally clock) by the rate sent.
      final clock = Stopwatch()..start();
      first = await source.capture();
      for (var i = 0; i < 2; i++) {
        await source.capture();
      }
      _fps = liveFps(clock.elapsed, 3);
    } on Object catch (e) {
      _set(state.copyWith(phase: LivePhase.error, error: 'Camera stopped: $e'));
      return;
    }
    final connected = await _connect({
      'type': 'start',
      'fps': _fps,
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
    if (connected.started == null) return;
    _beginStreaming();
  }

  /// Open the socket, send [hello] and wait for `started`.
  ///
  /// Returns the `started` event, or the reason it failed. With [quiet] (a resume attempt)
  /// the failure is left for the caller to show, so the screen does not flash an error
  /// between attempts.
  Future<({Json? started, _Refused? refused})> _connect(Json hello, {bool quiet = false}) async {
    final api = ref.read(apiClientProvider);
    final generation = _generation;
    final socket = ref.read(liveSocketFactoryProvider)(api.liveUri());
    void fail(String message) {
      if (!quiet) _set(state.copyWith(phase: LivePhase.error, error: message));
    }

    try {
      await socket.ready;
    } on Object {
      await socket.close();
      final message = 'Cannot reach the live server at ${api.config.baseUrl}';
      fail(message);
      return (started: null, refused: _Refused(null, message));
    }
    if (generation != _generation) {
      await socket.close();
      return (started: null, refused: _Refused(null, 'cancelled'));
    }
    // The old socket may still be open (a decode error, not a drop); close it so the server
    // sees the old connection end. Do not wait on its cleanup.
    final old = _socket;
    unawaited(_events?.cancel());
    if (old != null) unawaited(old.close());
    _socket = socket;
    final started = _started = Completer<Json>();
    _events = socket.events.listen(_onEvent, onDone: _onClosed, onError: (_) => _onClosed());
    socket.sendJson(hello);
    try {
      final event = await started.future.timeout(kStartTimeout);
      final size = (width: asInt(event['width'])!, height: asInt(event['height'])!);
      _set(
        state.copyWith(
          phase: LivePhase.live,
          sessionId: event['session_id'] as String,
          size: size,
          courtCorners: (event['corners'] as List?)?.map((p) => asPoint(p)!).toList(),
          fps: asDouble(event['fps']),
          stages: (event['stages'] as Map? ?? const {}).map(
            (k, v) => MapEntry(k as String, v as bool),
          ),
        ),
      );
      return (started: event, refused: null);
    } on Object catch (e) {
      final refused = e is _Refused
          ? e
          : _Refused(
              null,
              e is TimeoutException
                  ? 'The live server did not answer'
                  : 'Unexpected answer from the live server: $e',
            );
      if (_socket == socket) _socket = null;
      await socket.close();
      fail(refused.message);
      return (started: null, refused: refused);
    } finally {
      if (identical(_started, started)) _started = null;
    }
  }

  void _beginStreaming() {
    if (_streaming) return;
    _streaming = true;
    unawaited(_stream(_generation));
  }

  Future<void> _stream(int generation) async {
    final interval = Duration(microseconds: (1e6 / _fps).round());
    final clock = Stopwatch()..start();
    final first = _nextFrame; // after a resume the count goes on, the clock starts again
    bool current() => _streaming && !_disposed && generation == _generation;
    while (current()) {
      final due = interval * (_nextFrame - first);
      if (clock.elapsed < due) await Future<void>.delayed(due - clock.elapsed);
      final source = _source, socket = _socket;
      if (source == null || socket == null || state.phase != LivePhase.live) {
        await Future<void>.delayed(interval);
        continue;
      }
      try {
        final frame = await source.capture();
        if (!current() || state.phase != LivePhase.live) continue;
        socket.sendFrame(
          _nextFrame++,
          DateTime.now().millisecondsSinceEpoch.toDouble(),
          frame.jpeg,
        );
        _set(state.copyWith(sentFrames: state.sentFrames + 1, speedKmh: state.speedKmh));
      } on Object catch (e) {
        if (!current()) return;
        _streaming = false;
        // Save what arrived so far, then let go of the socket so the server frees the GPU.
        socket.sendJson({'type': 'stop'});
        unawaited(_events?.cancel());
        _events = null;
        _socket = null;
        unawaited(socket.close());
        _set(
          state.copyWith(
            phase: LivePhase.error,
            error: 'Camera stopped: $e. The session so far is saved to History.',
          ),
        );
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
    // The list index is the server's frame number, which hits, rallies and line calls refer
    // to: frames whose events were lost in a drop are padded with empty entries, and a frame
    // event repeated after a resume replaces its entry.
    final info = FrameInfo(
      frame: frame,
      nearPos: asPoint(court?['near']),
      farPos: asPoint(court?['far']),
      shuttlePos: asPoint(court?['shuttle']),
      shuttleSpeedKmh: speed,
      rallyState: e['rally_state'] as String?,
    );
    final frames = state.frames;
    while (frames.length < frame) {
      frames.add(FrameInfo(frame: frames.length));
    }
    frame < frames.length ? frames[frame] = info : frames.add(info);
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
        // Every frame repeats the open rally's start, so a lost `rally` event cannot leave
        // the rally clock blank or stale.
        rallyStartFrame: asInt(e['rally_start_frame']),
        clearRallyStart: e.containsKey('rally_start_frame') && e['rally_start_frame'] == null,
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
      _ => e['detail'] as String? ?? 'Live error',
    };
    final starting = _started;
    if (starting != null && !starting.isCompleted) {
      // An answer to start / resume: _connect decides what to show.
      starting.completeError(_Refused(code, message));
      return;
    }
    // Mid-session: frame-level problems, an override of an unknown call (not_found) and a
    // server-side failure (internal: the server closes the socket and keeps the session, so
    // the app resumes) do not end the session.
    if (const {'bad_frame', 'bad_message', 'not_found', 'internal'}.contains(code)) return;
    _streaming = false;
    _set(state.copyWith(phase: LivePhase.error, error: message));
  }

  /// The socket closed: resume if it dropped mid-session, fail fast if it was saving.
  void _onClosed() {
    if (_disposed) return;
    if (state.phase == LivePhase.stopping) {
      final saved = _saved;
      if (saved != null && !saved.isCompleted) {
        saved.completeError(StateError('the connection closed before the save was confirmed'));
      }
      return;
    }
    if (state.phase != LivePhase.live) return;
    unawaited(_reconnect(_generation));
  }

  Future<void> _reconnect(int generation) async {
    _set(state.copyWith(phase: LivePhase.reconnecting));
    String? lastError;
    for (final wait in kReconnectDelays) {
      await Future<void>.delayed(wait);
      if (_disposed || generation != _generation || state.phase != LivePhase.reconnecting) {
        return;
      }
      final result = await _connect({'type': 'resume', 'session_id': state.sessionId}, quiet: true);
      if (result.started != null) return;
      final code = result.refused?.code;
      // not_found: the server has not noticed the drop yet (or the session is gone); keep
      // trying until the attempts run out. Other refusals will not change on a retry.
      if (code != null && code != 'not_found') {
        lastError = result.refused!.message;
        break;
      }
    }
    if (_disposed || generation != _generation) return;
    _streaming = false;
    _set(
      state.copyWith(
        phase: LivePhase.error,
        error:
            lastError ??
            'Lost the connection to the server. The session is saved to History once the '
                'server lets go of it (about a minute).',
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
    final saved = _saved = Completer<String?>();
    socket.sendJson({'type': 'stop'});
    try {
      // Saving runs the final analysis pass, which takes longer on long sessions.
      final jobId = await saved.future.timeout(const Duration(seconds: 90));
      _set(state.copyWith(phase: LivePhase.saved, savedJobId: jobId));
    } on Object {
      _set(
        state.copyWith(
          phase: LivePhase.error,
          error:
              'The server did not confirm the save. If frames arrived, the session should '
              'still appear in History.',
        ),
      );
    }
    await socket.close();
    if (_socket == socket) _socket = null;
  }
}

final liveControllerProvider = AutoDisposeNotifierProvider<LiveController, LiveState>(
  LiveController.new,
);
