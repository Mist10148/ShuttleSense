// Settings > AI Coach (docs/coach-personality/ui-ux.md): one tap picks a preset, Undo puts
// it back, Customize opens the page, older servers are named, and the card fits every theme
// and size.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/core/audio/skin_sounds.dart';
import 'package:shuttlesense_app/core/theme/app_skin.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/coach_personality/personality_notifier.dart';
import 'package:shuttlesense_app/features/settings/widgets/coach_personality_card.dart';

import 'fakes/fake_api_client.dart';
import 'helpers.dart';

const _card = Scaffold(body: SingleChildScrollView(child: CoachPersonalityCard()));
final _quiet = [skinSoundsProvider.overrideWithValue(const SilentSkinSounds())];

Health _health({bool personality = true}) => Health(
  version: '0.1.0',
  schemaVersion: '1.7',
  device: 'cpu',
  authRequired: false,
  stages: kAllStages,
  chatAvailable: true,
  coachPersonality: personality,
);

ProviderContainer _c(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(CoachPersonalityCard)));

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a tap picks a preset and Undo puts the last one back', (tester) async {
    await pumpScreen(
      tester,
      _card,
      api: FakeApiClient(health: _health()),
      size: laptop,
    );
    expect(find.textContaining('Default · Balanced'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('coach-preset-mentor')));
    expect(_c(tester).read(personalityProvider).activeId, 'preset:mentor');
    expect(find.textContaining('Mentor · Patient'), findsOneWidget);
    expect(find.text('Coach is now Mentor'), findsOneWidget);
    expect(find.textContaining('Your swing has good speed'), findsOneWidget); // its preview
    await _tap(tester, find.text('Undo'));
    expect(_c(tester).read(personalityProvider).activeId, 'preset:default');
  });

  testWidgets('the Undo note goes away by itself', (tester) async {
    await pumpScreen(tester, _card, api: FakeApiClient(health: _health()), size: laptop);
    await _tap(tester, find.byKey(const ValueKey('coach-preset-witty')));
    expect(find.text('Coach is now Witty'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('Coach is now Witty'), findsNothing);
  });

  testWidgets('Custom and Customize open the personality page', (tester) async {
    final visited = await pumpScreen(
      tester,
      _card,
      api: FakeApiClient(health: _health()),
      size: laptop,
    );
    await _tap(tester, find.byKey(const ValueKey('coach-customize')));
    expect(visited, ['/settings/coach']);
  });

  testWidgets('a phone shows eight presets until asked for all', (tester) async {
    await pumpScreen(tester, _card, api: FakeApiClient(health: _health()));
    expect(find.byKey(const ValueKey('coach-preset-cute_shy')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('coach-show-all')));
    expect(find.byKey(const ValueKey('coach-preset-cute_shy')), findsOneWidget);
  });

  testWidgets('an older server is named and the presets are off', (tester) async {
    await pumpScreen(
      tester,
      _card,
      api: FakeApiClient(health: _health(personality: false)),
      size: laptop,
    );
    expect(find.text('This server uses the standard coach voice'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('coach-preset-witty')), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_c(tester).read(personalityProvider).activeId, 'preset:default');
  });

  for (final skin in AppSkin.values) {
    for (final MapEntry(key: name, value: size) in kSizes.entries) {
      testWidgets('the card lays out in ${skin.label} on a $name', (tester) async {
        await pumpScreen(
          tester,
          _card,
          api: FakeApiClient(health: _health()),
          size: size,
          skin: skin,
          overrides: _quiet,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
