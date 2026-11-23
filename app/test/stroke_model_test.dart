// Stroke model choice (Phase 11, T11.8): CNN, LSTM or Random Forest per job.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/features/results/widgets/summary_chart.dart';
import 'package:shuttlesense_app/features/upload/upload_screen.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';

Health health([List<String>? strokeModels = const ['cnn', 'lstm', 'rf']]) => Health(
  version: '0.1.0',
  schemaVersion: '1.4',
  device: 'cpu',
  authRequired: false,
  stages: kAllStages,
  strokeModels: strokeModels,
);

/// Answers every request with a job that echoes the stroke model, and keeps the bodies.
class _CapturingAdapter implements HttpClientAdapter {
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? body, Future? cancel) {
    final sent = Map<String, dynamic>.from(options.data as Map);
    bodies.add(sent);
    final model = sent['stroke_model'];
    return Future.value(
      ResponseBody.fromString(
        '{"id": "j1", "video_id": "v1", "status": "queued", "progress": 0, '
        '"created_at": "2026-11-14T00:00:00Z"'
        '${model == null ? '' : ', "stroke_model": "$model"'}}',
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
  test('the model sent is one the server has', () {
    expect(resolveStrokeModel('lstm', null), 'lstm'); // server not asked yet
    expect(resolveStrokeModel('lstm', health()), 'lstm');
    expect(resolveStrokeModel('lstm', health(['cnn', 'rf'])), 'cnn'); // first installed
    expect(resolveStrokeModel(null, health(['rf'])), 'rf');
    expect(resolveStrokeModel('cnn', health([])), isNull); // nothing installed
    expect(resolveStrokeModel('cnn', health(null)), isNull); // server without the choice

    const options = JobOptions(overlays: {}, strokeModel: 'lstm');
    expect(options.submittable(health(['rf'])).strokeModel, 'rf');
    expect(options.submittable(health(null)).strokeModel, isNull);
    // The other copies keep the choice.
    expect(options.copyWith(referee: true).strokeModel, 'lstm');
    expect(options.withStartScore((near: 1, far: 2)).strokeModel, 'lstm');
    expect(options.withMatch(options.match).strokeModel, 'lstm');
  });

  test('POST /jobs carries the stroke model and the job echoes it', () async {
    final adapter = _CapturingAdapter();
    final dio = Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = adapter;
    final api = ApiClient(const ServerConfig(baseUrl: 'http://test'), dio: dio);
    final job = await api.createJob(
      videoId: 'v1',
      options: const JobOptions(overlays: {}, strokeModel: 'rf'),
    );
    expect(adapter.bodies.single, containsPair('stroke_model', 'rf'));
    expect(job.strokeModel, 'rf');
    expect(job.options.strokeModel, 'rf'); // a retry runs the same model
    // Nothing is sent when no model is chosen, and an older server's job has none.
    final old = await api.createJob(
      videoId: 'v1',
      options: const JobOptions(overlays: {}),
    );
    expect(adapter.bodies.last.containsKey('stroke_model'), isFalse);
    expect(old.strokeModel, isNull);
  });

  test('health and the record read the new fields', () {
    final h = Health.fromJson({
      'version': '0.1.0',
      'schema_version': '1.4',
      'device': 'cpu',
      'auth_required': false,
      'stages': <String>[],
      'stroke_models': ['cnn', 'rf'],
    });
    expect(h.strokeModels, ['cnn', 'rf']);
    expect(h.schemaMatches, isTrue);
    expect(goldenRecord().strokeModel, isNull);
    expect(goldenRecord().copyWith().strokeModel, isNull);
  });

  group('upload screen', () {
    SegmentedButton<String> field(WidgetTester tester) => tester.widget<SegmentedButton<String>>(
      find.ancestor(of: find.text('Random Forest'), matching: find.byType(SegmentedButton<String>)),
    );

    /// The stroke model field sits under the "Advanced" disclosure on the upload screen.
    Future<void> openAdvanced(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Advanced'));
      await tester.pump(); // lay out the scrolled page before tapping
      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();
    }

    testWidgets('the choice is remembered and a missing model is disabled', (tester) async {
      final api = FakeApiClient(health: health(['cnn', 'rf']));
      await pumpScreen(tester, const UploadScreen(), api: api, size: tablet);
      await openAdvanced(tester);
      expect(find.text('Stroke model'), findsOneWidget);
      expect(field(tester).selected, {'cnn'});
      final lstm = field(tester).segments.firstWhere((s) => s.value == 'lstm');
      expect(lstm.enabled, isFalse);
      expect(find.text('Not installed on this server: LSTM.'), findsOneWidget);

      await tester.ensureVisible(find.text('Random Forest'));
      await tester.tap(find.text('Random Forest'));
      await tester.pumpAndSettle();
      expect(field(tester).selected, {'rf'});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('options.stroke_model'), 'rf');
    });

    testWidgets('a remembered model the server lacks falls back to an installed one', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        const UploadScreen(),
        api: FakeApiClient(health: health(['rf'])),
        prefs: {'options.stroke_model': 'lstm'},
        size: tablet,
      );
      await openAdvanced(tester);
      expect(field(tester).selected, {'rf'});
    });

    testWidgets('an older server shows no choice', (tester) async {
      await pumpScreen(tester, const UploadScreen(), api: FakeApiClient(health: health(null)));
      expect(find.text('Stroke model'), findsNothing);
    });

    testWidgets('a server with no stroke model says so', (tester) async {
      await pumpScreen(
        tester,
        const UploadScreen(),
        api: FakeApiClient(health: health([])),
        size: tablet,
      );
      await openAdvanced(tester);
      expect(field(tester).segments.every((s) => !s.enabled), isTrue);
      expect(find.textContaining('No stroke model is installed'), findsOneWidget);
    });

    testWidgets('the choice fits a phone at 200% text size', (tester) async {
      await pumpScreen(tester, const UploadScreen(), api: FakeApiClient(health: health()));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('the results chart names the model that labelled the strokes', (tester) async {
    final record = ClipRecord.fromJson({...goldenRecordJson(), 'stroke_model': 'lstm'});
    expect(record.strokeModel, 'lstm');
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SummaryChart(summary: record.summary, strokeModel: record.strokeModel),
          ),
        ),
      ),
    );
    expect(find.text('Strokes named by the LSTM model'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(child: SummaryChart(summary: record.summary)),
        ),
      ),
    );
    expect(find.textContaining('Strokes named by'), findsNothing);
  });
}
