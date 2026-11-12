// Doubles match setup (Phase 9, T9.10): court choice, first server and receiver slots.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/shared/widgets/start_score_field.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/features/live/live_controller.dart';
import 'package:shuttlesense_app/shared/widgets/match_setup_field.dart';

/// Answers every request with a job and keeps the request bodies.
class _CapturingAdapter implements HttpClientAdapter {
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? body, Future? cancel) {
    bodies.add(Map<String, dynamic>.from(options.data as Map));
    return Future.value(
      ResponseBody.fromString(
        '{"id": "j1", "video_id": "v1", "status": "queued", "progress": 0, '
        '"created_at": "2026-11-12T00:00:00Z", "court": "doubles", '
        '"first_server_id": "near_2", "first_receiver_id": "far_1"}',
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('a doubles job sends the court and the first server and receiver', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = adapter;
    final api = ApiClient(const ServerConfig(baseUrl: 'http://test'), dio: dio);
    const match = MatchSetup(
      bestOf: 3,
      firstServer: 'near',
      court: 'doubles',
      firstServerId: 'near_2',
      firstReceiverId: 'far_1',
    );
    final options = const JobOptions(overlays: {}, referee: true).withMatch(match);
    final job = await api.createJob(videoId: 'v1', options: options);
    expect(adapter.bodies.single, containsPair('court', 'doubles'));
    expect(adapter.bodies.single, containsPair('first_server_id', 'near_2'));
    expect(adapter.bodies.single, containsPair('first_receiver_id', 'far_1'));
    expect(adapter.bodies.single, containsPair('best_of', 3));
    expect((job.court, job.firstServerId), ('doubles', 'near_2'));
    expect(
      job.options.match,
      const MatchSetup(court: 'doubles', firstServerId: 'near_2', firstReceiverId: 'far_1'),
    );
    // Singles requests stay as they were: no court, no slots.
    await api.createJob(
      videoId: 'v1',
      options: const JobOptions(overlays: {}, referee: true, firstServer: 'far'),
    );
    expect(adapter.bodies.last.containsKey('court'), isFalse);
    expect(adapter.bodies.last.containsKey('first_server_id'), isFalse);
    // Doubles without the referee still tracks four players.
    await api.createJob(
      videoId: 'v1',
      options: const JobOptions(overlays: {}, court: 'doubles'),
    );
    expect(adapter.bodies.last['court'], 'doubles');
    expect(adapter.bodies.last.containsKey('best_of'), isFalse);
  });

  test('the service order is sent only when both slots are known', () {
    const half = MatchSetup(court: 'doubles', firstServer: 'far', firstServerId: 'far_1');
    expect(half.toJson().containsKey('first_server_id'), isFalse);
    final full = half.withService(serverId: 'far_1', receiverId: 'near_2');
    expect(full.toJson()['first_receiver_id'], 'near_2');
    // A new side or court clears the slots, which belong to a side.
    expect(full.withFirstServer('near').firstServerId, isNull);
    expect(full.withCourt('singles').hasServiceOrder, isFalse);
  });

  testWidgets('doubles shows who serves and receives first', (tester) async {
    var value = const MatchSetup(court: 'doubles');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: MatchSetupField(
                value: value,
                showCourt: true,
                onChanged: (m) => setState(() => value = m),
              ),
            ),
          ),
        ),
      ),
    );
    // No side chosen yet: nothing to pick.
    expect(find.text('Serves first'), findsNothing);
    await tester.tap(find.text('Far'));
    await tester.pumpAndSettle();
    expect(find.text('Serves first'), findsOneWidget);
    await tester.tap(find.byType(DropdownButton<String?>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Far player 2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButton<String?>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Near player 1').last);
    await tester.pumpAndSettle();
    expect(value.firstServerId, 'far_2');
    expect(value.firstReceiverId, 'near_1');
    expect(value.toJson()['first_server'], 'far');
    await tester.tap(find.text('Singles'));
    await tester.pumpAndSettle();
    expect(find.text('Serves first'), findsNothing);
    expect(value.hasServiceOrder, isFalse);
  });

  test('the live match setup reads both the old and the new saved form', () async {
    Future<MatchSetup> load(List<String> saved) async {
      SharedPreferences.setMockInitialValues({'live.match': saved});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      return container.read(liveMatchSetupProvider);
    }

    expect(
      await load(['3', 'near', 'doubles']),
      const MatchSetup(bestOf: 3, firstServer: 'near', court: 'doubles'),
    );
    expect((await load(['1', 'far', 'doubles', 'far_1', 'near_2'])).firstReceiverId, 'near_2');
    expect((await load(['1', 'far', 'doubles', 'bogus', ''])).firstServerId, isNull);
    expect(await load(['x']), kDefaultMatchSetup);
  });

  testWidgets('the start score names pairs in doubles', (tester) async {
    Widget field(bool doubles) => MaterialApp(
      home: Scaffold(
        body: StartScoreField(value: (near: 3, far: 2), doubles: doubles, onChanged: (_) {}),
      ),
    );
    await tester.pumpWidget(field(true));
    expect(find.text('Near pair'), findsOneWidget);
    expect(find.text('Far pair'), findsOneWidget);
    await tester.pumpWidget(field(false));
    expect(find.text('Near player'), findsOneWidget);
  });
}
