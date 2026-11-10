import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shuttlesense_app/data/models/json.dart';
import 'package:shuttlesense_app/features/live/frame_source.dart';
import 'package:shuttlesense_app/features/live/live_socket.dart';

/// A camera that returns a decodable still (the server is fake too).
class FakeFrameSource implements FrameSource {
  FakeFrameSource({this.error});

  /// Thrown by start() (permission denied, no camera).
  final CameraUnavailable? error;

  /// Set to make the next captures fail (the camera was unplugged or taken).
  Object? captureError;
  int captures = 0;
  int width = 1280;
  int height = 720;
  bool disposed = false;

  @override
  String get label => 'Back camera';

  @override
  Future<void> start() async {
    if (error != null) throw error!;
  }

  @override
  Future<CapturedFrame> capture() async {
    if (captureError != null) throw captureError!;
    captures++;
    return (
      jpeg: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8'
        '/x8AAwMCAO+jP1sAAAAASUVORK5CYII=',
      ),
      width: width,
      height: height,
    );
  }

  @override
  Widget preview() => const ColoredBox(key: Key('camera-preview'), color: Colors.black);

  @override
  Future<void> dispose() async => disposed = true;
}

/// Records what the app sends; the test pushes server events with [emit].
class FakeLiveSocket implements LiveSocket {
  FakeLiveSocket(this.uri, {this.fail = false, this.onHello});

  final Uri uri;
  final bool fail;

  /// Answers the first message (start / resume), e.g. with a `started` event.
  final Json? Function(Json hello)? onHello;
  final sent = <Json>[];
  final frames = <Uint8List>[];
  final _events = StreamController<Json>.broadcast();
  bool closed = false;
  bool replyToStop = true;
  Object? stopError;

  @override
  Future<void> get ready => fail ? Future.error(Exception('refused')) : Future.value();

  @override
  Stream<Json> get events => _events.stream;

  @override
  void sendJson(Json message) {
    sent.add(message);
    if (sent.length == 1) {
      final reply = onHello?.call(message);
      if (reply != null) scheduleMicrotask(() => emit(reply));
    }
    if (message['type'] == 'stop' && stopError != null) throw stopError!;
    if (message['type'] == 'stop' && replyToStop) {
      scheduleMicrotask(
        () => emit({
          'type': 'saved',
          'job_id': 'live1',
          'video_id': 'v9',
          'stats': <String, dynamic>{},
        }),
      );
    }
  }

  @override
  void sendFrame(int index, double captureMs, Uint8List jpeg) =>
      frames.add(framePacket(index, captureMs, jpeg));

  /// Sends [event] as the server would: through JSON, so maps are `Map<String, dynamic>`.
  void emit(Json event) {
    if (!_events.isClosed) _events.add(jsonDecode(jsonEncode(event)) as Json);
  }

  /// The connection drops (server restart, Wi-Fi).
  Future<void> drop() => _events.close();

  @override
  Future<void> close() async {
    closed = true;
    if (!_events.isClosed) await _events.close();
  }
}

Json startedEvent({String id = 's1', bool resumed = false, int frames = 0}) => {
  'type': 'started',
  'session_id': id,
  'resumed': resumed,
  'fps': 15.0,
  'width': 1280,
  'height': 720,
  'frames': frames,
  'stages': {'tracking': true, 'pose': true},
  'corners': [
    [212.0, 650.0],
    [1068.0, 650.0],
    [880.0, 210.0],
    [400.0, 210.0],
  ],
  'budget_ms': 300,
};

Json frameEvent(int frame, {bool visible = true, String state = 'in_play'}) => {
  'type': 'frame',
  'frame': frame,
  'time_s': frame / 15,
  'client_frame': frame,
  'ts': 0.0,
  'shuttle': visible ? {'x': 600.0 + frame, 'y': 300.0, 'visible': 1} : {'visible': 0},
  'players': {
    'near': {
      'bbox': [500.0, 380.0, 120.0, 260.0],
      'keypoints': <dynamic>[],
      'score': 0.9,
    },
    'far': null,
  },
  'court': {
    'near': [2.6, 2.0],
    'far': [2.6, 11.4],
    'shuttle': visible ? [2.4, 8.0] : null,
  },
  'speed_kmh': 120.0 + frame,
  'rally_state': state,
  'rally_start_frame': 0,
  'strokes_in_rally': 2,
  'latency_ms': 42.0,
};

Json lineCallEvent({
  String call = 'out',
  bool uncertain = true,
  int id = 0,
  int rally = 0,
  int frame = 1,
  String? override,
}) => {
  'type': 'line_call',
  'line_call': {
    'id': id,
    'rally_index': rally,
    'frame': frame,
    'time_s': frame / 15,
    'call': call,
    'landing_xy': [5.21, 10.5],
    'margin_cm': -3.0,
    'confidence': 0.3,
    'uncertain': uncertain,
    'court': 'singles',
    'override': override == null ? null : {'call': override, 'at': '2026-11-05T09:20:00Z'},
  },
};
