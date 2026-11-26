import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/theme/app_theme.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/features/coach/coach_screen.dart';
import 'package:shuttlesense_app/shared/widgets/coach_reply.dart';

import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/chat/chat_screen.dart';
import 'package:shuttlesense_app/features/practice/practice_followup.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

void main() {
  testWidgets('coach preserves identifiers and escaped delimiters alongside emphasis', (
    tester,
  ) async {
    const source =
        r'near_side_score far__side__score \*tap\* \_here\_ '
        r'**near_side_score** and _soft_ and *a \*single\* cue*.';
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CoachReply(source))));
    final text = tester.widget<Text>(
      find.descendant(of: find.byType(CoachReply), matching: find.byType(Text)),
    );
    final span = text.textSpan! as TextSpan;
    expect(
      span.toPlainText(),
      'near_side_score far__side__score *tap* _here_ near_side_score and soft and a *single* cue.',
    );
    final styled = span.children!.whereType<TextSpan>().where((s) => s.style != null);
    expect(styled.map((s) => s.text), ['near_side_score', 'soft', 'a *single* cue']);
    expect(styled.first.style!.fontWeight, FontWeight.bold);
    expect(styled.last.style!.fontStyle, FontStyle.italic);
  });

  for (final practice in [false, true]) {
    testWidgets('formatted reply seeks its citation in ${practice ? "practice" : "results"}', (
      tester,
    ) async {
      const question = 'Why **here**?';
      final events = [
        {
          'type': 'done',
          'message': {
            'role': 'assistant',
            'text': 'Watch the **shuttle** [t=2.5s]',
            'at': '2026-11-24T00:00:00Z',
            'citations': [
              {'frame': 75, 'time_s': 2.5},
            ],
          },
        },
      ];
      double? sought;
      List<String>? visited;
      if (practice) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: PracticeFollowup(
                  version: 'v1',
                  enabled: true,
                  suggestions: const [],
                  onAsk: (_, _, _, _) => Stream.fromIterable(events),
                  onSeek: (s) => sought = s,
                  onReload: () {},
                ),
              ),
            ),
          ),
        );
      } else {
        final api = FakeApiClient(
          health: const Health(
            version: '0.1',
            schemaVersion: '1.7',
            device: 'cpu',
            authRequired: false,
            stages: [],
            chatAvailable: true,
            chatMaxMessages: 2,
          ),
        )..chatEvents = events;
        visited = await pumpScreen(tester, const ChatScreen(jobId: 'job1'), api: api);
      }
      await tester.enterText(find.byType(TextField), question);
      if (practice) {
        await tester.pump();
        await tester.tap(find.text('Send question'));
      } else {
        await tester.testTextInput.receiveAction(TextInputAction.send);
      }
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SelectableText, question), findsOneWidget);
      final reply = find.byType(CoachReply);
      final body = tester.widget<Text>(
        find.descendant(of: reply, matching: find.byType(Text)).first,
      );
      expect(
        body.textSpan!.toPlainText(),
        practice ? 'Watch the shuttle' : 'Watch the shuttle [t=2.5s]',
      );
      await tester.ensureVisible(find.text('0:02.5'));
      await tester.tap(find.text('0:02.5'));
      await tester.pumpAndSettle();
      if (practice) {
        expect(sought, 2.5);
      } else {
        expect(visited!.last, '/jobs/job1/results');
      }
    });
  }

  testWidgets('coach formats selectable replies and preserves a literal question', (tester) async {
    const reply =
        '## Timing\n\nWatch the **shuttle**.\n\n1. *Move* into position and keep your racket up until the return.\n- Recover';
    Widget bubble(String role, String text) => CoachBubble(
      turn: CoachTurn(
        message: ChatMessage(role: role, text: text, at: DateTime.utc(2026)),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              child: Column(children: [bubble('user', '**why**'), bubble('assistant', reply)]),
            ),
          ),
        ),
      ),
    );
    expect(find.widgetWithText(SelectableText, '**why**'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(CoachReply), matching: find.byType(SelectionArea)),
      findsOneWidget,
    );
    expect(find.text('Timing'), findsOneWidget);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
    final spans = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.textSpan)
        .whereType<TextSpan>()
        .expand((s) => s.children ?? <InlineSpan>[])
        .whereType<TextSpan>();
    expect(spans.singleWhere((s) => s.text == 'shuttle').style!.fontWeight, FontWeight.bold);
    expect(spans.singleWhere((s) => s.text == 'Move').style!.fontStyle, FontStyle.italic);
    expect(tester.takeException(), isNull);
  });
}
