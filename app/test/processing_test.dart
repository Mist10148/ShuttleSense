import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/core/notifications/job_notifier.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/job.dart';
import 'package:shuttlesense_app/data/repositories/analysis_repository.dart';
import 'package:shuttlesense_app/features/processing/processing_screen.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

/// Records what would have been shown.
class FakeJobNotifier implements JobNotifier {
  final shown = <String>[];

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> jobFinished({required String jobId, required bool ok}) async =>
      shown.add('$jobId ${ok ? 'done' : 'failed'}');
}

/// Serves [job] through jobProvider without the polling loop (no pending timers in tests).
Override fixedJob(Job job) => jobProvider.overrideWith((ref, _) => Stream.value(job));

void main() {
  test('formatDuration', () {
    expect(formatDuration(const Duration(seconds: 42)), '42 s');
    expect(formatDuration(const Duration(seconds: 65)), '1 min 05 s');
  });

  testWidgets('running job shows the stage, elapsed time and cancel asks first', (tester) async {
    final api = FakeApiClient();
    final running = Job.fromJson(jobJson(status: 'running', progress: 0.5));
    await pumpScreen(
      tester,
      const ProcessingScreen(jobId: 'job1'),
      api: api,
      overrides: [fixedJob(running)],
    );
    expect(find.text('Running: Players and pose'), findsOneWidget);
    expect(find.textContaining('Elapsed'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Cancel processing?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(api.calls, isNot(contains('deleteJob job1')));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel job'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('deleteJob job1'));
  });

  testWidgets('queued re-render shows no elapsed time from the earlier run', (tester) async {
    // jobJson keeps started_at for queued jobs, like an older server after a re-render.
    final queued = Job.fromJson(jobJson(status: 'queued', progress: 0));
    await pumpScreen(
      tester,
      const ProcessingScreen(jobId: 'job1'),
      overrides: [fixedJob(queued)],
      settle: false, // the queued progress bar animates forever
    );
    await tester.pump();
    expect(find.textContaining('Waiting in queue'), findsOneWidget);
    expect(find.textContaining('Elapsed'), findsNothing);
  });

  testWidgets('failed job can be retried with the same options', (tester) async {
    final api = FakeApiClient(
      jobs: [Job.fromJson(jobJson(status: 'failed', error: 'stage pose failed'))],
    );
    final visited = await pumpScreen(tester, const ProcessingScreen(jobId: 'job1'), api: api);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('createJob vid1 trail,boxes'));
    expect(visited, ['/jobs/job2']);
  });

  testWidgets('a live session whose video failed to render opens its results', (tester) async {
    final json = jobJson(status: 'failed', error: 'render failed: disk full');
    final failed = Job.fromJson({
      ...json,
      'mode': 'live',
      'outputs': {...json['outputs'] as Map<String, dynamic>, 'record': true},
    });
    final api = FakeApiClient(jobs: [failed]);
    final visited = await pumpScreen(tester, const ProcessingScreen(jobId: 'job1'), api: api);
    expect(find.text('Try again'), findsNothing);
    await tester.tap(find.text('View results'));
    await tester.pumpAndSettle();
    expect(visited, ['/jobs/job1/results']);
    expect(api.calls.where((c) => c.startsWith('createJob')), isEmpty);
  });

  for (final (background, enabled, expected) in [
    (true, true, ['job1 done']),
    (false, true, <String>[]),
    (true, false, <String>[]),
  ]) {
    testWidgets('a job finishing (background: $background, setting: $enabled) notifies: '
        '$expected', (tester) async {
      final jobs = StreamController<Job>();
      addTearDown(jobs.close);
      final notifier = FakeJobNotifier();
      await pumpScreen(
        tester,
        const ProcessingScreen(jobId: 'job1'),
        prefs: {'ui.notifyWhenDone': enabled},
        settle: false,
        overrides: [
          jobProvider.overrideWith((ref, _) => jobs.stream),
          jobNotifierProvider.overrideWithValue(notifier),
          appInBackgroundProvider.overrideWithValue(() => background),
        ],
      );
      jobs.add(Job.fromJson(jobJson(status: 'running', progress: 0.5)));
      await tester.pump();
      jobs.add(Job.fromJson(jobJson()));
      await tester.pump();
      await tester.pump();
      expect(notifier.shown, expected);
    });
  }

  testWidgets('a finished job opens the results', (tester) async {
    final done = Job.fromJson(jobJson());
    final visited = await pumpScreen(
      tester,
      const ProcessingScreen(jobId: 'job1'),
      overrides: [fixedJob(done)],
    );
    expect(visited, ['/jobs/job1/results']);
  });

  testWidgets('a link to the chat of a finished job stays on the chat', (tester) async {
    // The processing page sits under results and chat; its first load of the done job
    // must not take the user away from the page they opened.
    final router = await pumpJobRoutes(tester, [
      fixedJob(Job.fromJson(jobJson())),
    ], initialLocation: '/jobs/job1/results/chat');
    await pumpFrames(tester);
    expect(router.routeInformationProvider.value.uri.path, '/jobs/job1/results/chat');
    expect(find.text('chat'), findsOneWidget);
  });

  testWidgets('a re-render shows progress instead of the old results', (tester) async {
    // First build: the finished job. After the re-render invalidates the provider: queued.
    final builds = <StreamController<Job>>[];
    final router = await pumpJobRoutes(tester, [
      jobProvider.overrideWith((ref, _) {
        final controller = StreamController<Job>();
        ref.onDispose(controller.close);
        builds.add(controller);
        return controller.stream;
      }),
    ]);
    builds.last.add(Job.fromJson(jobJson()));
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/jobs/job1/results');

    // What showRerenderSheet does after POST /render.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ProcessingScreen, skipOffstage: false)),
    );
    container.invalidate(jobProvider('job1'));
    router.go('/jobs/job1');
    await pumpFrames(tester);
    expect(router.routeInformationProvider.value.uri.path, '/jobs/job1');

    builds.last.add(Job.fromJson(jobJson(status: 'queued', progress: 0)));
    await pumpFrames(tester);
    expect(router.routeInformationProvider.value.uri.path, '/jobs/job1');
    builds.last.add(Job.fromJson(jobJson()));
    await pumpFrames(tester);
    expect(router.routeInformationProvider.value.uri.path, '/jobs/job1/results');
  });

  testWidgets('polling keeps going through rate limiting', (tester) async {
    final api = FakeApiClient()..failWith = ApiException('Too many requests', statusCode: 429);
    await pumpScreen(tester, const ProcessingScreen(jobId: 'job1'), api: api, settle: false);
    await tester.pump();
    api.failWith = null;
    await tester.pump(kPollBackoff.first);
    await tester.pumpAndSettle();
    expect(find.text('Lost connection to server'), findsNothing);
    expect(api.calls.where((c) => c == 'getJob job1'), hasLength(2));
  });

  testWidgets('polling backs off on errors before giving up', (tester) async {
    final api = FakeApiClient()..failWith = ApiException('Cannot reach server');
    await pumpScreen(tester, const ProcessingScreen(jobId: 'job1'), api: api, settle: false);
    await tester.pump();
    expect(find.text('Lost connection to server'), findsNothing);
    for (final wait in kPollBackoff) {
      await tester.pump(wait);
    }
    await tester.pump();
    expect(find.text('Lost connection to server'), findsOneWidget);
    expect(api.calls.where((c) => c == 'getJob job1'), hasLength(kPollBackoff.length + 1));
  });
}

/// The app's own nesting: results is a child of the processing route, so the processing
/// screen (and its listener) stays mounted under the results screen.
Future<GoRouter> pumpJobRoutes(
  WidgetTester tester,
  List<Override> overrides, {
  String initialLocation = '/jobs/job1',
}) async {
  setSize(tester, phone);
  SharedPreferences.setMockInitialValues({'server.baseUrl': 'http://fake:8000'});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', builder: (_, _) => const Text('home')),
      GoRoute(
        path: '/jobs/:jobId',
        builder: (_, state) => ProcessingScreen(jobId: state.pathParameters['jobId']!),
        routes: [
          GoRoute(
            path: 'results',
            builder: (_, _) => const Scaffold(body: Text('results')),
            routes: [
              GoRoute(
                path: 'chat',
                builder: (_, _) => const Scaffold(body: Text('chat')),
              ),
            ],
          ),
        ],
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(FakeApiClient()),
        jobNotifierProvider.overrideWithValue(const NoopJobNotifier()),
        ...overrides,
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  return router;
}

/// Spinners never settle, so pump a fixed number of frames instead.
Future<void> pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
