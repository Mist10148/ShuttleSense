// T4.6 / T10.6: the access token reaches the server on every route the app uses.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';

void main() {
  group('with a token', () {
    const config = ServerConfig(baseUrl: 'http://192.168.1.20:8000', token: 'a b&c');
    final api = ApiClient(config);
    tearDownAll(api.close);

    test('the video and downloads carry it in the query, encoded', () {
      expect(api.videoUrl('job1'), 'http://192.168.1.20:8000/jobs/job1/video?token=a+b%26c');
      expect(api.summaryUrl('job1'), endsWith('/summary.json?token=a+b%26c'));
    });

    test('the live socket carries it and uses ws', () {
      final uri = api.liveUri();
      expect(uri.scheme, 'ws');
      expect(uri.path, '/live');
      expect(uri.queryParameters['token'], 'a b&c');
    });

    test('headers name it for players that can send them', () {
      expect(api.authHeaders, {'Authorization': 'Bearer a b&c'});
    });
  });

  test('without a token nothing is added', () {
    final api = ApiClient(const ServerConfig(baseUrl: 'https://court.example'));
    addTearDown(api.close);
    expect(api.videoUrl('job1'), 'https://court.example/jobs/job1/video');
    expect(api.authHeaders, isEmpty);
    expect(api.liveUri().scheme, 'wss');
    expect(api.liveUri().hasQuery, isFalse);
  });

  test('API calls send the bearer header (and none without a token)', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String?>[];
    server.listen((request) {
      seen.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(<Object>[]))
        ..close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final withToken = ApiClient(ServerConfig(baseUrl: base, token: 's3cret'));
    final without = ApiClient(ServerConfig(baseUrl: base));
    addTearDown(withToken.close);
    addTearDown(without.close);
    await withToken.listJobs();
    await without.listJobs();
    expect(seen, ['Bearer s3cret', null]);
  });
}
