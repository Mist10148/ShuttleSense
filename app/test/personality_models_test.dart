// Coach personality models (docs/coach-personality/schema.md): JSON round trips, unknown
// values falling back to defaults, bands and identity merging.
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/data/models/clip_record.dart';
import 'package:shuttlesense_app/data/models/health.dart';
import 'package:shuttlesense_app/features/coach_personality/personality_models.dart';

void main() {
  test('bands follow the documented ranges', () {
    expect([0, 20, 21, 40, 41, 60, 61, 80, 81, 100].map(AttrBand.of), [
      AttrBand.minimal,
      AttrBand.minimal,
      AttrBand.subtle,
      AttrBand.subtle,
      AttrBand.moderate,
      AttrBand.moderate,
      AttrBand.strong,
      AttrBand.strong,
      AttrBand.dominant,
      AttrBand.dominant,
    ]); // dart format off
  });

  test('a profile survives a JSON round trip', () {
    final p = PersonalityProfile(
      id: 'p_7f3a9k2x',
      name: 'Footwork bootcamp',
      basePreset: 'bold',
      overrides: const {PersonalityAttr.empathy: 60, PersonalityAttr.verbosity: 30},
      preferences: const CommunicationPrefs(
        responseLength: ResponseLength.concise,
        emoji: EmojiUsage.none,
        addressByName: true,
      ),
      identity: const CoachIdentity(coachName: 'Kai', coachPronouns: 'they/them'),
      vocabulary: const CoachVocabulary(preferred: ['kill']),
      instructions: 'Be strict about footwork.',
      createdAt: DateTime.utc(2026, 11, 27, 10),
      updatedAt: DateTime.utc(2026, 11, 27, 10, 5),
    );
    final back = PersonalityProfile.fromJson(p.toJson());
    expect(back, p);
    expect(back!.preferences.addressByName, isTrue);
    expect(p.toJson()['preferences']['addressStyle'], 'name');
  });

  test('unknown values fall back, bad profiles are skipped', () {
    final p = PersonalityProfile.fromJson({
      'id': 'p_aaaaaaaa',
      'name': 'X',
      'basePreset': 'pirate',
      'overrides': {'humor': 150, 'charm': 5, 'warmth': -2},
      'preferences': {'emoji': 'tons', 'initiative': 'proactive'},
      'identity': {'coachPronouns': 'xe/xem', 'language': 'klingon'},
    }, presetIds: {'default', 'bold'})!;
    expect(p.basePreset, 'default');
    expect(p.overrides, {PersonalityAttr.warmth: 0, PersonalityAttr.humor: 100});
    expect(p.preferences.emoji, EmojiUsage.preset);
    expect(p.preferences.initiative, Initiative.proactive);
    expect(p.identity!.coachPronouns, isNull);
    expect(p.identity!.language, isNull);
    expect(PersonalityProfile.fromJson({'name': 'no id'}), isNull);
    expect(PersonalityProfile.fromJson('nope'), isNull);
  });

  test('a profile identity sits on top of the global one', () {
    const global = CoachIdentity(coachName: 'Coach', playerNickname: 'Mo', language: 'fil');
    const own = CoachIdentity(coachName: 'Kai');
    expect(own.over(global), const CoachIdentity(coachName: 'Kai', playerNickname: 'Mo', language: 'fil'));
    expect(const CoachIdentity().isEmpty, isTrue);
    expect(const CoachIdentity(language: 'auto').isEmpty, isTrue);
  });

  test('settings know the active preset', () {
    const s = PersonalitySettings(activeId: 'preset:witty');
    expect(s.activePresetId, 'witty');
    expect(s.activeProfile, isNull);
    const p = PersonalityProfile(id: 'p_bbbbbbbb', name: 'Mine', basePreset: 'stoic');
    final t = s.copyWith(activeId: p.id, profiles: [p]);
    expect(t.activeProfile, p);
    expect(t.activePresetId, 'stoic');
    expect(t.toJson()['schemaVersion'], 1);
  });

  test('health and saved answers carry the personality fields', () {
    final base = {
      'version': '0.1.0',
      'schema_version': '1.7',
      'device': 'cpu',
      'auth_required': false,
      'stages': <String>[],
    };
    expect(Health.fromJson(base).coachPersonality, isFalse);
    expect(Health.fromJson({...base, 'coach_personality': true}).coachPersonality, isTrue);
    final m = ChatMessage.fromJson({
      'role': 'assistant',
      'text': 'hi',
      'personality_label': 'Mentor',
    });
    expect(m.personalityLabel, 'Mentor');
    expect(ChatMessage.fromJson({'role': 'user', 'text': 'q'}).personalityLabel, isNull);
  });
}
