import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../data/models/json.dart';

/// The WS /live connection (docs/API.md): JSON messages both ways, frames as binary.
abstract class LiveSocket {
  /// Completes when connected; fails when the server cannot be reached.
  Future<void> get ready;

  /// Server events, decoded. Ends when the connection closes.
  Stream<Json> get events;

  void sendJson(Json message);

  void sendFrame(int index, double captureMs, Uint8List jpeg);

  Future<void> close();
}

/// 12-byte header (uint32 frame index, float64 capture ms, little-endian), then the JPEG.
Uint8List framePacket(int index, double captureMs, Uint8List jpeg) {
  final header = ByteData(12)
    ..setUint32(0, index, Endian.little)
    ..setFloat64(4, captureMs, Endian.little);
  return Uint8List(12 + jpeg.length)
    ..setAll(0, header.buffer.asUint8List())
    ..setAll(12, jpeg);
}

class ChannelLiveSocket implements LiveSocket {
  ChannelLiveSocket(Uri uri) : _channel = WebSocketChannel.connect(uri);

  final WebSocketChannel _channel;

  @override
  Future<void> get ready => _channel.ready;

  @override
  late final Stream<Json> events = _channel.stream
      .where((m) => m is String)
      .map((m) => jsonDecode(m as String) as Json)
      .asBroadcastStream();

  @override
  void sendJson(Json message) => _channel.sink.add(jsonEncode(message));

  @override
  void sendFrame(int index, double captureMs, Uint8List jpeg) =>
      _channel.sink.add(framePacket(index, captureMs, jpeg));

  @override
  Future<void> close() async => _channel.sink.close();
}

/// Opens live connections; tests replace it with a fake server.
final liveSocketFactoryProvider = Provider<LiveSocket Function(Uri)>(
  (ref) => ChannelLiveSocket.new,
);
