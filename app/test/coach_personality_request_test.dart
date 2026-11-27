// The chosen personality travels with each coach question, the Default sends nothing, and
// switching mid-conversation keeps the history and marks the change (D50).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/coach/coach_screen.dart';
import 'package:shuttlesense_app/features/coach_personality/personality_notifier.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

Health _health() => Health(
  version: '0.1.0',
  schemaVersion: '1.7',
  device: 'cpu',
  authRequired: false,
  stages: kAllStages,
  chatAvailable: true,
  chatMaxMessages: 5,
);

Future<void> _ask(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(TextField), q);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pumpAndSettle();
}

ProviderContainer _c(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(CoachScreen)));

void main() {
  testWidgets('the Default coach sends no personality', (tester) async {
    final api = FakeApiClient(health: _health());
    await pumpScreen(tester, const CoachScreen(), api: api);
    await _ask(tester, 'How do I serve?');
    expect(api.personalities, [null]);
  });

  testWidgets('a chosen preset is sent with every question', (tester) async {
    final api = FakeApiClient(health: _health());
    await pumpScreen(
      tester,
      const CoachScreen(),
      api: api,
      prefs: {
        PersonalityNotifier.key: jsonEncode({
          'schemaVersion': 1,
          'activeProfileId': 'preset:mentor',
          'profiles': <Object>[],
        }),
      },
    );
    await _ask(tester, 'How do I serve?');
    expect(api.personalities.single?['preset'], 'mentor');
    expect(api.personalities.single?['label'], 'Mentor');
    expect(find.byTooltip('Coach personality: Mentor'), findsOneWidget);
  });

  testWidgets('switching keeps the history and marks the change', (tester) async {
    final api = FakeApiClient(health: _health());
    await pumpScreen(tester, const CoachScreen(), api: api);
    await _ask(tester, 'How do I serve?');

    await tester.tap(find.byKey(const ValueKey('personality-switcher')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('switch-preset-witty')),
      200,
      scrollable: find
          .descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable))
          .first,
    );
    await tester.tap(find.byKey(const ValueKey('switch-preset-witty')));
    await tester.pumpAndSettle();
    expect(_c(tester).read(personalityProvider).activeId, 'preset:witty');

    await _ask(tester, 'And the smash?');
    expect(find.text('Coach is now Witty'), findsOneWidget);
    expect(api.personalities.last?['preset'], 'witty');
    // The earlier turns are still sent, without the notice line.
    expect(api.coachHistories.last.map((t) => t['role']), ['user', 'assistant']);
    expect(tester.takeException(), isNull);
  });
}
