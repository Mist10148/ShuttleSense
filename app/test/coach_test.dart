import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/api_client.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/chat/chat_screen.dart';
import 'package:shuttlesense_app/features/mode/mode_screen.dart';
import 'package:shuttlesense_app/features/results/widgets/court_minimap.dart';
import 'package:shuttlesense_app/features/results/widgets/line_call_banner.dart';
import 'package:shuttlesense_app/features/results/widgets/results_layout.dart';
import 'package:shuttlesense_app/features/results/widgets/session_summary.dart';
import 'package:shuttlesense_app/shared/disclaimers.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

Health health({bool chat = true}) => Health(
  version: '0.1.0',
  schemaVersion: '1.1',
  device: 'cpu',
  authRequired: false,
  stages: kAllStages,
  chatAvailable: chat,
  chatMaxMessages: 2,
);

LineCall call({bool uncertain = true, String? override, String called = 'out'}) => LineCall(
  id: 0,
  rallyIndex: 0,
  frame: 55,
  timeS: 1.833,
  call: called,
  landing: (x: 5.21, y: 10.5),
  marginCm: -3,
  confidence: 0.3,
  uncertain: uncertain,
  overrideCall: override,
);

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('mode picker', () {
    for (final MapEntry(key: name, value: size) in kSizes.entries) {
      testWidgets('$name: picking a mode saves it and goes to Analyze', (tester) async {
        final visited = await pumpScreen(
          tester,
          const ModeScreen(),
          size: size,
          prefs: {'ui.mode': 'live'},
        );
        expect(find.text('Last used'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Upload clip'));
        await tester.pumpAndSettle();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('ui.mode'), 'upload');
        // In pumpScreen '/' is this screen, so going home shows it again with the new pick.
        expect(visited, isEmpty);
      });
    }

    testWidgets('meets tap target and contrast guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, const ModeScreen());
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  group('line call banner', () {
    testWidgets('uncertain call asks to confirm or override', (tester) async {
      final decided = <String>[];
      await tester.pumpWidget(host(LineCallBanner(call: call(), onDecide: decided.add)));
      expect(find.text('UNCERTAIN'), findsOneWidget);
      expect(find.textContaining('Automated call · 30% confidence'), findsOneWidget);
      expect(find.textContaining('3 cm outside the line'), findsOneWidget);
      await tester.tap(find.text('Confirm OUT'));
      await tester.tap(find.text('Call IN'));
      expect(decided, ['out', 'in']);
      expect(find.textContaining('official'), findsNothing);
    });

    testWidgets('a reviewed call shows the decision and offers the other one', (tester) async {
      await tester.pumpWidget(
        host(
          LineCallBanner(
            call: call(override: 'in'),
            onDecide: (_) {},
          ),
        ),
      );
      expect(find.text('IN'), findsOneWidget);
      expect(find.textContaining('Confirmed by referee'), findsOneWidget);
      expect(find.text('Call OUT'), findsOneWidget);
      expect(find.text('Call IN'), findsNothing);
    });

    test('banner shows recent calls and any call still waiting for review', () {
      final record = goldenRecord().copyWith(lineCalls: [call(uncertain: false, called: 'in')]);
      expect(bannerCall(record, 40), isNull); // before the landing
      expect(bannerCall(record, 60)?.id, 0);
      expect(bannerCall(record, 60 + 30 * 4), isNull); // a certain call fades away
      final waiting = goldenRecord().copyWith(lineCalls: [call()]);
      expect(bannerCall(waiting, 60 + 30 * 10)?.needsReview, isTrue);
      // A newer certain call does not hide an older one still waiting for review.
      const later = LineCall(
        id: 1,
        rallyIndex: 1,
        frame: 200,
        timeS: 6.667,
        call: 'in',
        landing: (x: 2.0, y: 10.0),
        marginCm: 150,
        confidence: 1,
        uncertain: false,
      );
      final both = goldenRecord().copyWith(lineCalls: [call(), later]);
      expect(bannerCall(both, 210)?.id, 1); // the new call is shown while recent
      expect(bannerCall(both, 210, prioritizeReview: true)?.id, 0);
      expect(bannerCall(both, 200 + 30 * 5)?.id, 0); // then the one to review comes back
    });
  });

  testWidgets('minimap draws a marker per landing', (tester) async {
    final record = goldenRecord();
    final painter = CourtPainter.fromRecord(
      record,
      59,
      lines: Colors.black,
      surface: Colors.white,
      players: AppTheme.playerColorsLight,
    );
    expect(painter.landings, hasLength(1));
    expect(painter.landings.single.$2, isTrue);
  });

  group('session summary', () {
    testWidgets('lists top fixes with seek chips and the disclaimer', (tester) async {
      final seeks = <Moment>[];
      var asked = false;
      await tester.pumpWidget(
        host(
          SessionSummary(
            record: goldenRecord(),
            onSeek: seeks.add,
            chatAvailable: true,
            onAskCoach: () => asked = true,
          ),
        ),
      );
      expect(find.text('Top things to fix'), findsOneWidget);
      expect(find.textContaining('Feet moving during the serve'), findsOneWidget);
      expect(find.text(kCoachingDisclaimer), findsOneWidget);
      await tester.tap(find.text('0:01.5').first);
      expect(seeks.single.frame, 45);
      await tester.tap(find.text('Ask your coach'));
      expect(asked, isTrue);
    });

    testWidgets('chat button is off with an explanation when the server has no key', (
      tester,
    ) async {
      await tester.pumpWidget(host(SessionSummary(record: goldenRecord(), onSeek: (_) {})));
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(find.textContaining('no Claude API key'), findsOneWidget);
    });

    for (final MapEntry(key: name, value: size) in kSizes.entries) {
      testWidgets('$name: results layout with a coach slot has no overflow', (tester) async {
        setSize(tester, size);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ResultsLayout(
                video: const AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ColoredBox(color: Colors.black),
                ),
                status: LineCallBanner(call: call(), onDecide: (_) {}),
                timeline: const SizedBox(),
                minimap: const SizedBox(height: 100),
                scoreboard: const SizedBox(height: 100),
                coach: SessionSummary(record: goldenRecord(), onSeek: (_) {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (size == phone) {
          expect(find.text('Coach'), findsOneWidget); // a fourth tab
        } else {
          expect(find.text('Top things to fix'), findsOneWidget);
        }
      });
    }
  });

  group('coach chat', () {
    testWidgets('streams an answer with citation chips', (tester) async {
      final api = FakeApiClient(health: health());
      await pumpScreen(
        tester,
        const ChatScreen(jobId: 'job1'),
        api: api,
        size: tablet,
      );
      expect(find.text(kChatPrivacy), findsOneWidget);
      await tester.tap(find.text('What should I fix first?'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('chat job1 What should I fix first?'));
      expect(find.text('What should I fix first?'), findsOneWidget); // the question bubble
      expect(find.text('Your elbow was bent on the smash [t=1.5s].'), findsOneWidget);
      expect(find.text('0:01.5'), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.text(kCoachingDisclaimer), findsOneWidget);
    });

    testWidgets('a citation chip goes back to the results player', (tester) async {
      final api = FakeApiClient(health: health());
      final visited = await pumpScreen(tester, const ChatScreen(jobId: 'job1'), api: api);
      await tester.enterText(find.byType(TextField), 'Why short?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      await tester.tap(find.text('0:01.5'));
      await tester.pumpAndSettle();
      expect(visited.last, '/jobs/job1/results');
    });

    testWidgets('server errors keep the chat usable', (tester) async {
      final api = FakeApiClient(health: health())
        ..chatEvents = [
          {'type': 'error', 'status': 429, 'detail': 'The coach is busy (rate limited).'},
        ];
      await pumpScreen(tester, const ChatScreen(jobId: 'job1'), api: api);
      await tester.tap(find.text('What should I fix first?'));
      await tester.pumpAndSettle();
      expect(find.text('The coach is busy (rate limited).'), findsOneWidget);
      expect(find.text('What should I fix first?'), findsOneWidget); // suggestion is back
      api.failWith = ApiException('coach chat is off', statusCode: 503);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(find.text('coach chat is off'), findsOneWidget);
    });

    testWidgets('an answer that stops before it is done says so', (tester) async {
      final api = FakeApiClient(health: health())
        ..chatEvents = [
          {'type': 'delta', 'text': 'Your elbow '},
        ];
      await pumpScreen(tester, const ChatScreen(jobId: 'job1'), api: api);
      await tester.tap(find.text('What should I fix first?'));
      await tester.pumpAndSettle();
      expect(find.textContaining('cut off'), findsOneWidget);
      expect(find.text('Your elbow '), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    });

    testWidgets('an unexpected failure mid-answer is shown, not swallowed', (tester) async {
      final api = FakeApiClient(health: health())
        ..chatEvents = [
          {'type': 'done', 'message': 'not a message'},
        ];
      await pumpScreen(tester, const ChatScreen(jobId: 'job1'), api: api);
      await tester.tap(find.text('What should I fix first?'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The coach could not answer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chat is disabled with an explanation without a key', (tester) async {
      await pumpScreen(
        tester,
        const ChatScreen(jobId: 'job1'),
        api: FakeApiClient(health: health(chat: false)),
      );
      expect(find.text('Coach chat is off on this server'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('the question limit stops new questions', (tester) async {
      final api = FakeApiClient(health: health());
      await pumpScreen(
        tester,
        const ChatScreen(jobId: 'job1'),
        api: api,
        size: laptop,
      );
      for (final q in ['one', 'two']) {
        await tester.enterText(find.byType(TextField), q);
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
      }
      expect(find.text('Question limit for this session reached'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    });

    testWidgets('meets tap target and contrast guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(
        tester,
        const ChatScreen(jobId: 'job1'),
        api: FakeApiClient(health: health()),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });
}
