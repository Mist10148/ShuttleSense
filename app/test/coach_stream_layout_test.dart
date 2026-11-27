import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/data/models/json.dart';
import 'package:shuttlesense_app/features/chat/chat_screen.dart';
import 'package:shuttlesense_app/features/practice/practice_followup.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

class _StreamingApi extends FakeApiClient {
  _StreamingApi(this.events)
    : super(
        health: const Health(
          version: 'test',
          schemaVersion: '1.7',
          device: 'cpu',
          authRequired: false,
          stages: [],
          chatAvailable: true,
          chatMaxMessages: 4,
        ),
      );

  final Stream<Json> events;

  @override
  Stream<Json> chat(String jobId, String message, {Json? personality}) => events;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Outfit');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      font.addFont(rootBundle.load('assets/fonts/Outfit-$weight.ttf'));
    }
    await font.load();
  });
  const answer =
      '## Footwork\n\nRead near_side_score and **recover**.\n'
      '1. Recover to base before your opponent strikes the shuttle again.\n'
      '  - Turn early\n    Keep balanced\n\n    Hold your finish.\n\n'
      '## Replay\n\nCheck the next contact [t=2.5s]';
  for (final practice in [true, false]) {
    final flow = practice ? 'practice' : 'results';
    testWidgets('large-text streamed layout in $flow', (tester) async {
      final events = StreamController<Json>();
      double? sought;
      final screen = practice
          ? Scaffold(
              body: SingleChildScrollView(
                child: PracticeFollowup(
                  version: 'v1',
                  enabled: true,
                  suggestions: const [],
                  onAsk: (_, _, _, _) => events.stream,
                  onSeek: (seconds) => sought = seconds,
                  onReload: () {},
                ),
              ),
            )
          : const ChatScreen(jobId: 'job1');
      final visited = await pumpScreen(
        tester,
        screen,
        api: _StreamingApi(events.stream),
        size: const Size(360, 780),
        textScaler: const TextScaler.linear(1.4),
      );
      await tester.enterText(find.byType(TextField), 'Why **here**?');
      if (practice) {
        await tester.pump();
        await tester.ensureVisible(find.text('Send question'));
        await tester.tap(find.text('Send question'));
      } else {
        await tester.testTextInput.receiveAction(TextInputAction.send);
      }
      final split = answer.indexOf('recover**') + 'recover*'.length;
      events.add({'type': 'delta', 'text': answer.substring(0, split)});
      await tester.pump();
      await tester.pump();
      expect(find.text('Read near_side_score and **recover*'), findsOneWidget);
      if (!practice) {
        expect(find.widgetWithText(SelectableText, 'Why **here**?'), findsOneWidget);
      }
      events.add({'type': 'delta', 'text': answer.substring(split)});
      await tester.pump();
      await tester.pump();
      final formatted = find.text('Read near_side_score and recover.', findRichText: true);
      expect(formatted, findsOneWidget);
      expect(tester.takeException(), isNull);
      events.add({
        'type': 'done',
        'message': {
          'role': 'assistant',
          'text': answer,
          'at': '2026-11-26T00:00:00Z',
          'citations': [
            {'frame': 75, 'time_s': 2.5},
          ],
        },
      });
      await tester.pump();
      unawaited(events.close());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pumpAndSettle();
      if (practice) {
        expect(find.widgetWithText(SelectableText, 'Why **here**?'), findsOneWidget);
      }
      expect(
        find.ancestor(of: find.text('Replay'), matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      expect(formatted, findsOneWidget);
      final heading = find.ancestor(
        of: find.text('Replay'),
        matching: find.byWidgetPredicate(
          (widget) => widget is Semantics && widget.properties.header == true,
        ),
      );
      expect(heading, findsOneWidget);
      final nested = find.text('Turn early\nKeep balanced\n\nHold your finish.');
      expect(tester.getTopLeft(nested).dx, greaterThan(tester.getTopLeft(find.text('1.')).dx));
      expect(find.text('Replay'), findsOneWidget);
      await tester.ensureVisible(find.text('0:02.5'));
      await tester.tap(find.text('0:02.5'));
      await tester.pumpAndSettle();
      if (practice) {
        expect(sought, 2.5);
      } else {
        expect(visited.last, '/jobs/job1/results');
      }
      expect(tester.takeException(), isNull);
    });
  }
}
