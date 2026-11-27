// The three coach chats carry the personality in their request body, and leave it out for
// the Default coach (D50, D58).
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';

/// Answers every request with one finished SSE answer and keeps the request bodies.
class _CapturingAdapter implements HttpClientAdapter {
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? body, Future? cancel) {
    bodies.add(Map<String, dynamic>.from(options.data as Map));
    return Future.value(
      ResponseBody.fromString(
        'data: {"type": "done", "message": {"role": "assistant", "text": "ok"}}\n\n',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/event-stream'],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const personality = {'v': 1, 'preset': 'mentor', 'label': 'Mentor'};

  late _CapturingAdapter adapter;
  late ApiClient api;

  setUp(() {
    adapter = _CapturingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = adapter;
    api = ApiClient(const ServerConfig(baseUrl: 'http://test'), dio: dio);
  });

  test('job chat, the general coach and the practice follow-up send it', () async {
    await api.chat('j1', 'hi', personality: personality).toList();
    await api.coachChat('hi', personality: personality).toList();
    await api.practiceChat('j1', 'hi', contextVersion: 'a' * 64, personality: personality).toList();
    for (final body in adapter.bodies) {
      expect(body['personality'], personality);
    }
    expect(adapter.bodies, hasLength(3));
  });

  test('the Default coach sends no personality key at all', () async {
    await api.chat('j1', 'hi').toList();
    await api.coachChat('hi').toList();
    await api.practiceChat('j1', 'hi', contextVersion: 'a' * 64).toList();
    for (final body in adapter.bodies) {
      expect(body.containsKey('personality'), isFalse);
    }
  });
}
