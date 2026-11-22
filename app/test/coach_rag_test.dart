import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/coach.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/repositories/analysis_repository.dart';
import 'package:shuttlesense_app/features/chat/chat_screen.dart';
import 'package:shuttlesense_app/features/coach/coach_report_card.dart';
import 'package:shuttlesense_app/features/coach/coach_screen.dart';
import 'package:shuttlesense_app/features/history/history_screen.dart';
import 'package:shuttlesense_app/shared/disclaimers.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

Health health({bool chat = true}) => Health(
  version: '0.1.0',
  schemaVersion: '1.7',
  device: 'cpu',
  authRequired: false,
  stages: kAllStages,
  chatAvailable: chat,
  chatMaxMessages: 5,
);

void main() {
  group('coach models', () {
    test('report and sources parse', () {
      final report = CoachReport.fromJson(FakeApiClient().coachReportJson);
      expect(report.generatedBy, 'gemini');
      expect(report.fromRules, isFalse);
      final moments = report.weaknesses.single.momentsAt(30);
      expect(moments.single.frame, 45);
      expect(moments.single.timeS, 1.5);
      expect(report.drills.single.kbSource, 'kb:drills#throw-and-reach-for-a-straight-arm');
      final sources = CoachSource.listFrom([
        {'id': 'kb:rules#scoring-system', 'title': 'Rules: Scoring system'},
      ]);
      expect(sources.single.title, 'Rules: Scoring system');
      expect(CoachSource.listFrom(null), isEmpty);
    });
  });

  group('general coach', () {
    for (final MapEntry(key: name, value: size) in kSizes.entries) {
      testWidgets('$name: answers with source chips and sends the history', (tester) async {
        final api = FakeApiClient(health: health());
        await pumpScreen(tester, const CoachScreen(), api: api, size: size);
        expect(find.text(kCoachPrivacy), findsOneWidget);
        await tester.tap(find.text('When should I split step?'));
        await tester.pumpAndSettle();
        expect(api.calls, contains('coachChat When should I split step?'));
        expect(
          find.text('Land the split step as they hit [kb:footwork#split-step].'),
          findsOneWidget,
        );
        expect(find.text('Split step'), findsOneWidget); // the source chip
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byType(TextField), 'And in doubles?');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        expect(api.coachHistories.last.map((t) => t['role']), ['user', 'assistant']);
      });
    }

    testWidgets('errors are shown and the question can be asked again', (tester) async {
      final api = FakeApiClient(health: health())
        ..coachEvents = [
          {'type': 'error', 'status': 429, 'detail': 'The coach is busy (Gemini rate limit).'},
        ];
      await pumpScreen(tester, const CoachScreen(), api: api);
      await tester.enterText(find.byType(TextField), 'Smash tips?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('The coach is busy (Gemini rate limit).'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Smash tips?'), findsOneWidget);
    });

    testWidgets('is off with an explanation without a key', (tester) async {
      await pumpScreen(
        tester,
        const CoachScreen(),
        api: FakeApiClient(health: health(chat: false)),
      );
      expect(find.text('The coach is off on this server'), findsOneWidget);
    });

    testWidgets('history has a way into the coach', (tester) async {
      final visited = await pumpScreen(tester, const HistoryScreen(), api: FakeApiClient());
      await tester.tap(find.byTooltip('Ask the coach'));
      await tester.pumpAndSettle();
      expect(visited.last, '/coach');
    });
  });

  group('session chat sources', () {
    testWidgets('kb sources of an answer show as chips', (tester) async {
      final api = FakeApiClient(health: health())
        ..chatEvents = [
          {
            'type': 'done',
            'message': {
              'role': 'assistant',
              'text': 'Reach up [kb:overhead_strokes#contact-point-for-overheads] [t=1.5s].',
              'at': '2026-11-05T09:20:00Z',
              'citations': [
                {'frame': 45, 'time_s': 1.5, 'hit_id': 2},
              ],
            },
            'disclaimer': 'Heuristic guidance',
            'sources': [
              {
                'id': 'kb:overhead_strokes#contact-point-for-overheads',
                'title': 'Overhead strokes: Contact point for overheads',
                'excerpt': 'Reach up to contact the shuttle.',
              },
            ],
          },
        ];
      await pumpScreen(
        tester,
        const ChatScreen(jobId: 'job1'),
        api: api,
        size: tablet,
      );
      await tester.tap(find.text('What should I fix first?'));
      await tester.pumpAndSettle();
      expect(find.text('0:01.5'), findsOneWidget);
      expect(find.text('Contact point for overheads'), findsOneWidget);
      await tester.tap(find.text('Contact point for overheads'));
      await tester.pumpAndSettle();
      expect(find.text('Reach up to contact the shuttle.'), findsOneWidget);
    });
  });

  group('coaching report card', () {
    Future<(FakeApiClient, List<Moment>)> pumpCard(
      WidgetTester tester, {
      FakeApiClient? api,
    }) async {
      final fake = api ?? FakeApiClient(health: health());
      final seeks = <Moment>[];
      setSize(tester, phone);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiClientProvider.overrideWithValue(fake)],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: CoachReportCard(jobId: 'job1', fps: 30, onSeek: seeks.add),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (fake, seeks);
    }

    testWidgets('shows the report and seeks to a weakness moment', (tester) async {
      final (api, seeks) = await pumpCard(tester);
      expect(find.text('Coaching report'), findsOneWidget);
      expect(find.text('3 hits in 1 rally. Top fix: bent hitting arm.'), findsOneWidget);
      expect(find.text('Strengths'), findsOneWidget);
      expect(find.text('Bent hitting arm at contact'), findsOneWidget);
      expect(find.text('Throw and reach for a straight arm'), findsOneWidget);
      expect(find.text('Straighter arm on smashes'), findsOneWidget);
      await tester.tap(find.text('0:01.5'));
      expect(seeks.single.frame, 45);
      await tester.tap(find.byTooltip('Write the report again'));
      await tester.pumpAndSettle();
      expect(api.calls, ['coachReport job1', 'coachReport job1 refresh']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('says when the report was built without AI', (tester) async {
      final api = FakeApiClient(health: health())
        ..coachReportJson = {'summary': 'No repeated pattern.', 'generated_by': 'rules'};
      await pumpCard(tester, api: api);
      expect(find.textContaining('no AI provider answered'), findsOneWidget);
    });
  });
}
