// Coach personality settings (docs/coach-personality/schema.md): defaults, saving and
// reading back, migration and fallbacks, profile actions and the request a chat carries.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuttlesense_app/core/config/server_config.dart';
import 'package:shuttlesense_app/features/coach_personality/personality_models.dart';
import 'package:shuttlesense_app/features/coach_personality/personality_notifier.dart';

Future<(ProviderContainer, SharedPreferences)> _container([
  Map<String, Object> prefs = const {},
]) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(p)]);
  addTearDown(c.dispose);
  return (c, p);
}

PersonalityNotifier _n(ProviderContainer c) => c.read(personalityProvider.notifier);

void main() {
  test('defaults to the Default coach and sends nothing', () async {
    final (c, _) = await _container();
    expect(c.read(personalityProvider).activeId, 'preset:default');
    expect(c.read(activePersonalityRequestProvider), isNull);
    expect(c.read(activePersonalityLabelProvider), 'Default');
  });

  test('picking a preset saves it and sends it', () async {
    final (c, prefs) = await _container();
    await _n(c).activatePreset('witty');
    final saved = jsonDecode(prefs.getString(PersonalityNotifier.key)!) as Map;
    expect(saved['activeProfileId'], 'preset:witty');
    expect(saved['schemaVersion'], 1);
    final req = c.read(activePersonalityRequestProvider)!;
    expect(req['preset'], 'witty');
    expect(req['overrides'], isEmpty);
    expect(req['label'], 'Witty');
  });

  test('a profile sends only real changes and merges the global identity', () async {
    final (c, _) = await _container();
    final n = _n(c);
    await n.setGlobal(const CoachIdentity(playerNickname: 'Mo', language: 'fil'));
    final draft = n
        .draftFrom(basePreset: 'bold')
        .copyWith(
          overrides: const {PersonalityAttr.empathy: 60, PersonalityAttr.assertiveness: 100},
          identity: () => const CoachIdentity(coachName: 'Kai'),
          instructions: 'Be strict about footwork.',
        );
    await n.saveProfile(draft, activate: true);
    final req = c.read(activePersonalityRequestProvider)!;
    expect(req['preset'], 'bold');
    expect(req['overrides'], {'empathy': 60}); // 100 is Bold's own assertiveness
    expect(req['identity'], {
      'coachName': 'Kai',
      'coachPronouns': null,
      'playerNickname': 'Mo',
      'language': 'fil',
    });
    expect(req['instructions'], 'Be strict about footwork.');
    expect(req['label'], 'Bold (custom)');
  });

  test('a name in use gets a number, rename and duplicate keep names unique', () async {
    final (c, _) = await _container();
    final n = _n(c);
    final a = (await n.saveProfile(n.draftFrom(basePreset: 'stoic', name: 'Mine')))!;
    final b = (await n.saveProfile(n.draftFrom(basePreset: 'stoic', name: 'mine')))!;
    expect(b.name, 'mine (2)');
    final copy = (await n.duplicate(a.id))!;
    expect(copy.name, 'Mine (copy)');
    expect(copy.id, isNot(a.id));
    await n.rename(copy.id, 'Mine');
    expect(c.read(personalityProvider).profiles.last.name, 'Mine (3)');
  });

  test('deleting the active profile falls back to its preset, and undo restores it', () async {
    final (c, _) = await _container();
    final n = _n(c);
    final p = (await n.saveProfile(n.draftFrom(basePreset: 'mentor'), activate: true))!;
    final removed = (await n.delete(p.id))!;
    expect(c.read(personalityProvider).activeId, 'preset:mentor');
    expect(c.read(personalityProvider).profiles, isEmpty);
    await n.undoDelete(removed);
    expect(c.read(personalityProvider).activeId, p.id);
    expect(c.read(personalityProvider).profiles.single.id, p.id);
  });

  test('restore clears a profile\'s changes but keeps its name', () async {
    final (c, _) = await _container();
    final n = _n(c);
    final p = (await n.saveProfile(
      n
          .draftFrom(basePreset: 'playful')
          .copyWith(instructions: 'x', overrides: const {PersonalityAttr.humor: 10}),
    ))!;
    await n.restoreDefaults(p.id);
    final back = c.read(personalityProvider).profiles.single;
    expect(back.name, p.name);
    expect(back.overrides, isEmpty);
    expect(back.instructions, '');
  });

  test('no more than twenty profiles', () async {
    final (c, _) = await _container();
    final n = _n(c);
    for (var i = 0; i < 21; i++) {
      await n.saveProfile(n.draftFrom(basePreset: 'default', name: 'P$i'));
    }
    expect(c.read(personalityProvider).profiles, hasLength(PersonalitySettings.maxProfiles));
  });

  test('unreadable data is kept aside and the player is told', () async {
    final (c, prefs) = await _container({PersonalityNotifier.key: '{not json'});
    final s = c.read(personalityProvider);
    expect(s.activeId, 'preset:default');
    expect(s.notice, contains('could not be read'));
    expect(prefs.getString('${PersonalityNotifier.key}.corrupt'), '{not json');
  });

  test('a newer version is shown but never written', () async {
    final doc = jsonEncode({
      'schemaVersion': 9,
      'activeProfileId': 'preset:stoic',
      'profiles': <Object>[],
    });
    final (c, prefs) = await _container({PersonalityNotifier.key: doc});
    expect(c.read(personalityProvider).readOnly, isTrue);
    expect(c.read(personalityProvider).activePresetId, 'stoic');
    await _n(c).activatePreset('witty');
    expect(prefs.getString(PersonalityNotifier.key), doc);
  });

  test('migration fixes dangling, duplicate and unknown values', () {
    final s = PersonalityNotifier.migrate({
      'schemaVersion': 1,
      'activeProfileId': 'p_gone0000',
      'profiles': [
        {'id': 'p_aaaaaaaa', 'name': 'A', 'basePreset': 'pirate'},
        {'id': 'p_aaaaaaaa', 'name': 'a', 'basePreset': 'bold'},
        {'name': 'no id'},
      ],
    });
    expect(s.activeId, 'preset:default');
    expect(s.profiles, hasLength(2));
    expect(s.profiles.first.basePreset, 'default');
    expect(s.profiles.last.id, isNot('p_aaaaaaaa'));
    expect(s.profiles.last.name, 'a (2)');
  });
}
