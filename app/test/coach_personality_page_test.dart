// The coach personality page (docs/coach-personality/ui-ux.md): sliders edit a draft that
// Save turns into an active profile; resets, guard hints and the discard question.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/coach_personality/coach_personality_screen.dart';
import 'package:shuttlesense_app/features/coach_personality/personality_models.dart';
import 'package:shuttlesense_app/features/coach_personality/personality_notifier.dart';

import 'helpers.dart';

ProviderContainer _c(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(CoachPersonalityScreen)));

CoachPersonalityScreenState _page(WidgetTester tester) =>
    tester.state<CoachPersonalityScreenState>(find.byType(CoachPersonalityScreen));

Finder _slider(PersonalityAttr a) =>
    find.descendant(of: find.byKey(ValueKey('attr-${a.name}')), matching: find.byType(Slider));

Future<void> _setSlider(WidgetTester tester, PersonalityAttr a, int value) async {
  await tester.ensureVisible(_slider(a));
  tester.widget<Slider>(_slider(a)).onChanged!(value.toDouble());
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pumpAndSettle(); // the page scrolls smoothly
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a slider change is a draft until Save, which makes an active profile', (
    tester,
  ) async {
    await pumpScreen(tester, const CoachPersonalityScreen(), size: tablet);
    final save = find.byKey(const ValueKey('personality-save'));
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await _setSlider(tester, PersonalityAttr.humor, 90);
    expect(find.text('90 · Dominant'), findsOneWidget);
    expect(find.text('1 change'), findsOneWidget);
    expect(_c(tester).read(personalityProvider).profiles, isEmpty); // not saved yet

    await _tap(tester, save);
    final s = _c(tester).read(personalityProvider);
    expect(s.profiles.single.name, 'Default (custom)');
    expect(s.profiles.single.overrides, {PersonalityAttr.humor: 90});
    expect(s.activeId, s.profiles.single.id);
    expect(find.textContaining('Coach is now Default (custom)'), findsOneWidget);
    expect(_page(tester).dirty, isFalse);
  });

  testWidgets('one slider resets to the preset, and all sliders reset together', (tester) async {
    await pumpScreen(tester, const CoachPersonalityScreen(), size: tablet);
    await _setSlider(tester, PersonalityAttr.humor, 90);
    await _setSlider(tester, PersonalityAttr.verbosity, 10);
    await _tap(tester, find.byKey(const ValueKey('attr-reset-humor')));
    expect(_page(tester).draft.overrides, {PersonalityAttr.verbosity: 10});
    await _tap(tester, find.byKey(const ValueKey('attr-reset-all')));
    expect(_page(tester).draft.overrides, isEmpty);
    expect(_page(tester).dirty, isFalse);
  });

  testWidgets('harsh combinations show a hint', (tester) async {
    await pumpScreen(tester, const CoachPersonalityScreen(), size: tablet);
    await _setSlider(tester, PersonalityAttr.warmth, 10);
    await _setSlider(tester, PersonalityAttr.sarcasm, 90);
    expect(find.byKey(const ValueKey('attr-hint-sarcasm')), findsOneWidget);
  });

  testWidgets('restore defaults asks, then clears the draft', (tester) async {
    await pumpScreen(tester, const CoachPersonalityScreen(), size: tablet);
    await _setSlider(tester, PersonalityAttr.humor, 90);
    await _tap(tester, find.byKey(const ValueKey('restore-defaults')));
    await _tap(tester, find.text('Restore'));
    expect(_page(tester).draft.overrides, isEmpty);
  });

  testWidgets('switching what is edited asks about unsaved changes', (tester) async {
    await pumpScreen(tester, const CoachPersonalityScreen(), size: tablet);
    await _setSlider(tester, PersonalityAttr.humor, 90);
    final switching = _page(tester).switchTo('preset:witty');
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    await switching;
    expect(_page(tester).target, 'preset:default');
    final again = _page(tester).switchTo('preset:witty');
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Discard')));
    await tester.pumpAndSettle();
    await again;
    expect(_page(tester).target, 'preset:witty');
    expect(_page(tester).draft.overrides, isEmpty);
  });

  testWidgets('Discard in the save bar throws the draft away', (tester) async {
    await pumpScreen(tester, const CoachPersonalityScreen(), size: tablet);
    await _setSlider(tester, PersonalityAttr.humor, 90);
    await tester.tap(find.byKey(const ValueKey('personality-discard')));
    await tester.pumpAndSettle();
    expect(_page(tester).dirty, isFalse);
    expect(find.byKey(const ValueKey('personality-discard')), findsNothing);
  });

  testWidgets('communication options change the draft and the request', (tester) async {
    await pumpScreen(tester, const CoachPersonalityScreen(), size: tablet);
    await _tap(tester, find.byTooltip('Show How the coach talks'));
    await _tap(
      tester,
      find.descendant(
        of: find.byKey(const ValueKey('pref-pushback')),
        matching: find.text('Challenging'),
      ),
    );
    expect(_page(tester).draft.preferences.criticalThinking, CriticalThinking.challenging);
    expect(find.text('Pushes back when the data disagrees.'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('personality-save')));
    final req = _c(tester).read(activePersonalityRequestProvider)!;
    expect((req['preferences'] as Map)['criticalThinking'], 'challenging');
  });

  for (final MapEntry(key: name, value: size) in kSizes.entries) {
    testWidgets('the page lays out on a $name', (tester) async {
      await pumpScreen(tester, const CoachPersonalityScreen(), size: size);
      expect(tester.takeException(), isNull);
      expect(find.text('Coach personality'), findsWidgets);
    });
  }
}
