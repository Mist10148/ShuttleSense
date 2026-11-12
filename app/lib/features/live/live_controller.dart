import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/clip_record.dart';
import '../../data/models/json.dart';
import '../../core/config/server_config.dart';
import '../../data/repositories/analysis_repository.dart';
import '../../shared/widgets/match_setup_field.dart';
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

/// What happened in the rally that just closed (the server's `coaching` event).
class RallySummary {
  const RallySummary({
    required this.index,
    this.game = 1,
    this.durationS,
    this.strokes = 0,
    this.peakSpeedKmh,
    this.winner,
    this.call,
    this.faults = const [],
  });

  final int index;
  final int game;
  final double? durationS;
  final int strokes;
  final double? peakSpeedKmh;
  final String? winner;
  final String? call;

  /// Form rules that failed in this rally: the tip to show and the stroke it was on.
  final List<({int hitId, String player, String? stroke, String? tip})> faults;

  factory RallySummary.fromJson(Json j) => RallySummary(
    index: asInt(j['index'])!,
    game: asInt(j['game']) ?? 1,
    durationS: asDouble(j['duration_s']),
    strokes: asInt(j['strokes']) ?? 0,
    peakSpeedKmh: asDouble(j['peak_speed_kmh']),
    winner: j['winner'] as String?,
    call: j['call'] as String?,
    faults: [
      for (final f in asList(j['faults']))
        (
          hitId: asInt(f['hit_id']) ?? 0,
          player: f['player'] as String? ?? 'near',
          stroke: f['stroke'] as String?,
          tip: f['tip'] as String?,
        ),
    ],
  );
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
    this.processedFrames,
    this.notice,
    this.coaching,
    this.lastRally,
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

  /// Frames the server processed with perception (from its `stats` events).
  final int? processedFrames;

  /// A short message for a snack bar (a decision that did not go through); the id makes
  /// the same text show again.
  final ({int id, String text})? notice;

  /// Session notes so far and what the last rally showed (between-rally coaching, F21).
  final Coaching? coaching;
  final RallySummary? lastRally;

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
    coaching: coaching,
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
    int? processedFrames,
    ({int id, String text})? notice,
    Coaching? coaching,
    RallySummary? lastRally,
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
    processedFrames: processedFrames ?? this.processedFrames,
    notice: notice ?? this.notice,
    coaching: coaching ?? this.coaching,
    lastRally: lastRally ?? this.lastRally,
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
  Future<void>? _cameraRelease;
  int _nextFrame = 0;
  final Stopwatch _captureClock = Stopwatch();
  ({int width, int height})? _captureSize;
  DeviceOrientation? _calibrationOrientation;
  DeviceOrientation? _captureOrientation;
  final _pendingImages = <int, Uint8List>{};
  Uint8List? _analyzedImage;
  bool _waitingForAnalysis = true;
  Duration? _lastAnalysisAt;
  bool _decisionAck = false;
  int _decisionSequence = 0;
  int? _pendingDecision;
  int? _pendingReviewId;
  Timer? _decisionTimeout;
  Completer<String?>? _saved;
  String? _expectedJobId;
  Completer<Json>? _started;

  /// Bumped by [_teardown]; loops and reconnects of an older session stop when it changes.
  int _generation = 0;

  /// The rate frames are sent at: what the camera managed when the session started.
  double _fps = kLiveTargetFps;

  FrameSource? get source => _source;
  Uint8List? get analyzedImage => _analyzedImage;
  bool get waitingForAnalysis =>
      _waitingForAnalysis ||
      _captureClock.elapsed - (_lastAnalysisAt ?? Duration.zero) >
          const Duration(milliseconds: 750);
  ({int width, int height})? get captureSize => _captureSize;

  DeviceOrientation? _orientation(FrameSource source) =>
      source is CameraFrameSource ? source.captureOrientation : null;

  void _clearImages() {
    _pendingImages.clear();
    _analyzedImage = null;
    _waitingForAnalysis = true;
    _lastAnalysisAt = null;
  }

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
    _captureClock
      ..stop()
      ..reset();
    _captureSize = null;
    _calibrationOrientation = null;
    _captureOrientation = null;
    _clearImages();
    _clearDecision();
    _started = null;
    _expectedJobId = null;
    final saved = _saved;
    _saved = null;
    if (saved != null && !saved.isCompleted) saved.complete(null);
    final events = _events, socket = _socket;
    _events = null;
    _socket = null;
    // Cancelling stops delivery at once, but its future and the close (which waits for the
    // server's close handshake) may take long or never finish: do not block on either.
    if (events != null) unawaited(events.cancel());
    if (socket != null) unawaited(socket.close());
    await _releaseCamera();
  }

  Future<void> _releaseCamera() async {
    final source = _source;
    _source = null;
    if (source == null) {
      await _cameraRelease;
      return;
    }
    _cameraRelease = Future<void>.sync(source.dispose).catchError((Object error) {
      debugPrint('Could not release the live camera: $error');
    });
    try {
      await _cameraRelease;
    } finally {
      _cameraRelease = null;
    }
  }

  Future<void> openCamera() async {
    if (_disposed) return;
    final cleanup = _teardown();
    final generation = _generation;
    await cleanup;
    if (_disposed || generation != _generation) return;
    _set(_fresh());
    final source = ref.read(frameSourceFactoryProvider)();
    try {
      await source.start();
    } on Object catch (e) {
      await source.dispose();
      if (_disposed || generation != _generation) return;
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
    final generation = _generation;
    try {
      final frame = await source.capture();
      if (_disposed || generation != _generation) return;
      _calibrationOrientation = _orientation(source);
      _set(
        state.copyWith(
          phase: LivePhase.calibrating,
          still: frame.jpeg,
          stillSize: (width: frame.width, height: frame.height),
          corners: const [],
        ),
      );
    } on Object catch (e) {
      if (_disposed || generation != _generation) return;
      _set(state.copyWith(error: 'Could not take a picture: $e'));
    }
  }

  void cancelCalibration() => _set(state.copyWith(phase: LivePhase.ready, corners: const []));

  /// Connect and start streaming; [corners] are in still pixels (null: no court).
  Future<void> start({List<Corner>? corners, ({int near, int far})? startScore}) async {
    final source = _source;
    if (source == null) return;
    final generation = _generation;
    _set(state.copyWith(phase: LivePhase.connecting, corners: corners ?? const []));
    final CapturedFrame first;
    try {
      // Time a few captures: still captures are slower than video on most devices, and the
      // server times everything (the recording, speeds, the rally clock) by the rate sent.
      final clock = Stopwatch()..start();
      first = await source.capture();
      if (_disposed || generation != _generation) return;
      final orientation = _orientation(source);
      if (corners != null &&
          corners.length == 4 &&
          (state.stillSize != (width: first.width, height: first.height) ||
              orientation != _calibrationOrientation)) {
        throw StateError('Camera orientation changed. Recalibrate the court before starting.');
      }
      for (var i = 0; i < 2; i++) {
        final sample = await source.capture();
        if (_disposed || generation != _generation) return;
        if (sample.width != first.width ||
            sample.height != first.height ||
            _orientation(source) != orientation) {
          throw StateError('Camera orientation changed. Start again and recalibrate.');
        }
      }
      _fps = liveFps(clock.elapsed, 3);
      _captureSize = (width: first.width, height: first.height);
      _captureOrientation = orientation;
    } on Object catch (e) {
      if (_disposed || generation != _generation) return;
      unawaited(_releaseCamera());
      _set(state.copyWith(phase: LivePhase.error, error: 'Camera stopped: $e'));
      return;
    }
    final match = ref.read(liveMatchSetupProvider);
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
      'court': match.court,
      'best_of': match.bestOf,
      'first_server': match.firstServer,
    });
    if (connected.started == null || _disposed || generation != _generation) return;
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
      if (!quiet && !_disposed && generation == _generation) {
        unawaited(_releaseCamera());
        _set(state.copyWith(phase: LivePhase.error, error: message));
      }
    }

    try {
      await socket.ready;
    } on Object {
      unawaited(socket.close());
      final message = 'Cannot reach the live server at ${api.config.baseUrl}';
      fail(message);
      return (started: null, refused: _Refused(null, message));
    }
    if (generation != _generation) {
      unawaited(socket.close());
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
    try {
      socket.sendJson(hello);
      final event = await started.future.timeout(kStartTimeout);
      if (_disposed || generation != _generation) {
        return (started: null, refused: _Refused(null, 'cancelled'));
      }
      final size = (width: asInt(event['width'])!, height: asInt(event['height'])!);
      _expectedJobId = event['job_id'] as String?;
      _seed(event);
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
          score: event['score'] == null ? null : Score.fromJson(event['score'] as Json),
          rallyState: event['rally_state'] as String?,
          rallyStartFrame: asInt(event['rally_start_frame']),
          clearRallyStart:
              event.containsKey('rally_start_frame') && event['rally_start_frame'] == null,
          strokesInRally: asInt(event['strokes_in_rally']),
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
      // A server that never answered may never finish the close handshake either.
      unawaited(socket.close());
      fail(refused.message);
      return (started: null, refused: refused);
    } finally {
      if (identical(_started, started)) _started = null;
    }
  }

  /// The session so far from `started`: a fresh start has only the start score, a resume
  /// gets back every hit, rally and call it missed while away.
  void _seed(Json started) {
    _decisionAck = started['decision_ack'] == true;
    _padFrames(asInt(started['frames']) ?? 0);
    if (!started.containsKey('rallies')) return; // an older backend
    state.hits
      ..clear()
      ..addAll(asList(started['hits']).map(Hit.fromJson));
    state.rallies
      ..clear()
      ..addAll(asList(started['rallies']).map(Rally.fromJson));
    state.lineCalls
      ..clear()
      ..addAll(asList(started['line_calls']).map(LineCall.fromJson));
    final coaching = started['coaching'] as Json?;
    final summary = started['rally_summary'] as Json?;
    _clearDecision();
    _set(
      state.copyWith(
        speedKmh: state.speedKmh,
        coaching: coaching == null ? null : Coaching.fromJson(coaching),
        lastRally: summary == null ? null : RallySummary.fromJson(summary),
      ),
    );
  }

  void _padFrames(int count) {
    final frames = state.frames;
    while (frames.length < count) {
      frames.add(FrameInfo(frame: frames.length));
    }
  }

  void _beginStreaming() {
    if (_streaming) return;
    _captureClock.start();
    _streaming = true;
    unawaited(_stream(_generation));
  }

  Future<void> _stream(int generation) async {
    final interval = Duration(microseconds: (1e6 / _fps).round());
    final clock = Stopwatch()..start();
    var first = _nextFrame; // after a resume the count goes on, the clock starts again
    bool current() => _streaming && !_disposed && generation == _generation;
    while (current()) {
      final due = interval * (_nextFrame - first);
      if (clock.elapsed < due) await Future<void>.delayed(due - clock.elapsed);
      if (!current()) return;
      final source = _source, socket = _socket;
      if (source == null || socket == null || state.phase != LivePhase.live) {
        // Paused (reconnecting): restart the pace from here, or a resume would send every
        // frame "missed" while away back to back.
        clock.reset();
        first = _nextFrame;
        await Future<void>.delayed(interval);
        continue;
      }
      try {
        final frame = await source.capture();
        if (!current() || state.phase != LivePhase.live || socket != _socket) continue;
        if (_captureSize != (width: frame.width, height: frame.height) ||
            _captureOrientation != _orientation(source)) {
          throw StateError('Camera orientation changed. Start a new session and recalibrate.');
        }
        final index = _nextFrame++;
        _pendingImages[index] = frame.jpeg;
        if (_pendingImages.length > 12) _pendingImages.remove(_pendingImages.keys.first);
        socket.sendFrame(index, _captureClock.elapsedMicroseconds / 1000.0, frame.jpeg);
        _set(state.copyWith(sentFrames: state.sentFrames + 1, speedKmh: state.speedKmh));
      } on Object catch (e) {
        if (!current() || socket != _socket) continue;
        await _stop(captureError: e);
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
        // Kept in frame order: hitAt and the timeline assume it, and the server may commit
        // an earlier hit after a later one.
        final hit = Hit.fromJson(e['hit'] as Json);
        final hits = state.hits;
        var at = hits.length;
        while (at > 0 && hits[at - 1].frame > hit.frame) {
          at--;
        }
        hits.insert(at, hit);
        _set(state.copyWith(speedKmh: state.speedKmh));
      case 'line_call':
        final call = LineCall.fromJson(e['line_call'] as Json);
        final i = state.lineCalls.indexWhere((c) => c.id == call.id);
        i < 0 ? state.lineCalls.add(call) : state.lineCalls[i] = call;
        // A new call is felt as well as seen: the referee may be watching the court.
        if (i < 0) unawaited(HapticFeedback.mediumImpact());
        _set(state.copyWith(speedKmh: state.speedKmh));
      case 'coaching':
        final summary = e['rally_summary'] as Json?;
        _set(
          state.copyWith(
            coaching: Coaching.fromJson(e['coaching'] as Json),
            lastRally: summary == null ? null : RallySummary.fromJson(summary),
            speedKmh: state.speedKmh,
          ),
        );
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
        if (_matchesDecision(e)) _clearDecision();
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
      case 'stats':
        _set(state.copyWith(processedFrames: asInt(e['processed']), speedKmh: state.speedKmh));
      case 'saved':
        final saved = _saved;
        if (saved != null && !saved.isCompleted) saved.complete(e['job_id'] as String?);
      case 'error':
        _onServerError(e);
    }
  }

  void _onFrame(Json e) {
    final clientFrame = asInt(e['client_frame']);
    final matchingImage = e['skipped'] == true ? null : _pendingImages[clientFrame];
    _waitingForAnalysis = matchingImage == null;
    if (matchingImage != null) {
      _analyzedImage = matchingImage;
      _lastAnalysisAt = _captureClock.elapsed;
    }
    if (clientFrame != null) _pendingImages.removeWhere((index, _) => index <= clientFrame);
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
    _padFrames(frame);
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
        trail: matchingImage == null ? state.trail : trail,
        players: matchingImage == null ? state.players : players,
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
    if (_matchesDecision(e) &&
        (_decisionAck || const {'not_found', 'bad_message'}.contains(code))) {
      _clearDecision();
      _notify(message);
      return;
    }
    // Mid-session: frame-level problems, an override of an unknown call (not_found) and a
    // server-side failure (internal: the server closes the socket and keeps the session, so
    // the app resumes) do not end the session.
    if (code == 'not_found') {
      // A decision for a rally or call the server does not have, or nothing to undo.
      _notify(e['detail'] as String? ?? 'The server did not find that rally or call');
      return;
    }
    if (code == 'capture_gap') {
      _notify(message);
      return;
    }
    if (const {'bad_frame', 'bad_message'}.contains(code)) return;
    if (state.phase == LivePhase.stopping) {
      final saved = _saved;
      if (saved != null && !saved.isCompleted) saved.completeError(StateError(message));
      return;
    }
    if (code == 'internal') return;
    _streaming = false;
    _clearDecision();
    // Let go of the socket so the server detaches the session and frees the GPU.
    final socket = _socket;
    _socket = null;
    unawaited(_events?.cancel());
    _events = null;
    if (socket != null) unawaited(socket.close());
    unawaited(_releaseCamera());
    _set(state.copyWith(phase: LivePhase.error, error: message));
  }

  int _notices = 0;

  void _notify(String text) =>
      _set(state.copyWith(notice: (id: ++_notices, text: text), speedKmh: state.speedKmh));

  /// Whether a referee decision can reach the server now.
  bool get canDecide =>
      state.phase == LivePhase.live && _socket != null && _pendingDecision == null;

  int? get pendingReviewId => _pendingReviewId;

  bool _matchesDecision(Json event) =>
      _pendingDecision != null && (!_decisionAck || event['decision_id'] == _pendingDecision);

  void _clearDecision() {
    _decisionTimeout?.cancel();
    _decisionTimeout = null;
    _pendingDecision = null;
    _pendingReviewId = null;
  }

  /// Send a decision, or say why it cannot be sent (no silent drop while reconnecting).
  void _decide(Json message) {
    final socket = _socket;
    if (state.phase != LivePhase.live || socket == null) {
      _notify('Not connected: the decision was not sent. Try again once live.');
      return;
    }
    if (_pendingDecision != null) return;
    final id = ++_decisionSequence;
    _pendingDecision = id;
    _pendingReviewId = message['line_call_id'] as int?;
    _decisionTimeout = Timer(const Duration(seconds: 5), () {
      if (_decisionAck) {
        unawaited(_reconnect(_generation));
        return;
      }
      _clearDecision();
      _notify('Decision unconfirmed. Check the score before trying again.');
    });
    try {
      socket.sendJson({...message, if (_decisionAck) 'decision_id': id});
    } on Object {
      _clearDecision();
      _notify('Could not send the decision. Check the connection and try again.');
      return;
    }
    _set(state.copyWith(speedKmh: state.speedKmh));
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
    _clearImages();
    _decisionTimeout?.cancel();
    if (!_decisionAck) _clearDecision();
    final socket = _socket;
    _socket = null;
    unawaited(_events?.cancel());
    _events = null;
    if (socket != null) unawaited(socket.close());
    _set(state.copyWith(phase: LivePhase.reconnecting, trail: const [], players: const {}));
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
    unawaited(_releaseCamera());
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
      _decide({'type': 'override', 'line_call_id': lineCallId, 'call': call});

  /// Set a rally's winner, or clear it ([winner] null) so it does not count.
  Future<void> correct(int rallyIndex, String? winner) async =>
      _decide({'type': 'correct', 'rally_index': rallyIndex, 'winner': winner});

  /// A point for a rally the system missed.
  void award(String winner) => _decide({'type': 'award', 'winner': winner});

  /// Take back the newest correction or award.
  void undo() => _decide({'type': 'undo'});

  /// Give up connecting or reconnecting and go back to the camera. A session the server
  /// already started is saved to History once its resume window runs out.
  Future<void> cancel() async {
    final hadSession = state.sessionId != null;
    await openCamera();
    if (hadSession) {
      _notify('Stopped trying. What reached the server is saved to History in about a minute.');
    }
  }

  /// Stop streaming and wait for the server to save the session.
  Future<void> stop() => _stop();

  Future<void> _stop({Object? captureError}) async {
    final socket = _socket;
    if (socket == null || state.phase != LivePhase.live) return;
    final generation = _generation;
    _streaming = false;
    _clearImages();
    _clearDecision();
    final cameraReleased = _releaseCamera();
    _set(state.copyWith(phase: LivePhase.stopping));
    final saved = _saved = Completer<String?>();
    String? jobId;
    String? error;
    var unconfirmed = false;
    try {
      socket.sendJson({'type': 'stop'});
      // Saving runs the final analysis pass, which takes longer on long sessions.
      jobId = await saved.future.timeout(const Duration(seconds: 90));
    } on Object {
      unconfirmed = true;
    } finally {
      if (identical(_saved, saved)) _saved = null;
      if (_socket == socket) {
        _socket = null;
        unawaited(_events?.cancel());
        _events = null;
        unawaited(socket.close());
      }
    }
    if (_expectedJobId case final String id when unconfirmed) {
      jobId = await _findSavedJob(id, generation);
    }
    if (unconfirmed && jobId == null) {
      error = 'The server did not confirm the save. Check History for the session.';
    }
    if (captureError != null) {
      final outcome =
          error ??
          (jobId == null ? 'No frames were saved.' : 'The session so far is saved to History.');
      error = 'Camera stopped: $captureError. $outcome';
    }
    await cameraReleased;
    if (_disposed || generation != _generation) return;
    _set(
      state.copyWith(
        phase: error == null ? LivePhase.saved : LivePhase.error,
        savedJobId: jobId,
        error: error,
      ),
    );
  }

  Future<String?> _findSavedJob(String id, int generation) async {
    if (_disposed || generation != _generation) return null;
    final api = ref.read(apiClientProvider);
    for (final delay in [
      Duration.zero,
      const Duration(milliseconds: 500),
      const Duration(seconds: 1),
    ]) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      if (_disposed || generation != _generation) return null;
      try {
        final job = await api.getJob(id).timeout(const Duration(seconds: 2));
        if (job.id == id && job.mode == 'live') return id;
      } on Exception {
        // The job may still be saving, or the HTTP connection may be recovering too.
      }
    }
    return null;
  }
}

final liveControllerProvider = AutoDisposeNotifierProvider<LiveController, LiveState>(
  LiveController.new,
);

/// Match settings for the next live session (best of, first server, singles or doubles
/// lines); remembered on the device.
class LiveMatchSetupNotifier extends Notifier<MatchSetup> {
  static const _key = 'live.match';

  @override
  MatchSetup build() {
    final saved = ref.read(sharedPreferencesProvider).getStringList(_key);
    if (saved == null || saved.length != 3) return kDefaultMatchSetup;
    return (
      bestOf: saved[0] == '3' ? 3 : 1,
      firstServer: const {'near', 'far'}.contains(saved[1]) ? saved[1] : null,
      court: saved[2] == 'doubles' ? 'doubles' : 'singles',
    );
  }

  Future<void> set(MatchSetup setup) async {
    state = setup;
    await ref.read(sharedPreferencesProvider).setStringList(_key, [
      '${setup.bestOf}',
      setup.firstServer ?? '',
      setup.court,
    ]);
  }
}

final liveMatchSetupProvider = NotifierProvider<LiveMatchSetupNotifier, MatchSetup>(
  LiveMatchSetupNotifier.new,
);

/// Score at the start of a live session that joins a game under way (P3 referee). Kept
/// apart from the session so it survives calibrating the court; cleared once used.
final liveStartScoreProvider = StateProvider<({int near, int far})?>((ref) => null);
