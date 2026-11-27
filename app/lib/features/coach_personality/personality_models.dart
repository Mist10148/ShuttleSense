import 'package:flutter/foundation.dart';

import '../../data/models/json.dart';

/// The ten personality attributes, in the fixed order every vector uses
/// (docs/coach-personality/attributes.md). Values are 0-100 tendencies, not frequencies.
enum PersonalityAttr {
  warmth('Warmth', 'Cool and neutral', 'Openly kind and encouraging'),
  humor('Humor', 'Serious', 'Jokes are part of the voice'),
  sarcasm('Sarcasm', 'Sincere', 'Dry irony and snark'),
  formality('Formality', 'Casual', 'Formal and precise'),
  enthusiasm('Enthusiasm', 'Calm and flat', 'Energetic and excited'),
  directness('Directness', 'Gentle lead-in', 'Answer first, blunt'),
  empathy('Empathy', 'Task-focused', 'Notices and names feelings'),
  creativity('Creativity', 'Conventional', 'Metaphors and new drills'),
  assertiveness('Assertiveness', 'Suggests', 'Pushes and sets expectations'),
  verbosity('Verbosity', 'Terse', 'Thorough and long');

  const PersonalityAttr(this.label, this.low, this.high);

  final String label;
  final String low;
  final String high;
}

/// How strongly an attribute shows (attributes.md, intensity bands).
enum AttrBand {
  minimal('Minimal'),
  subtle('Subtle'),
  moderate('Moderate'),
  strong('Strong'),
  dominant('Dominant');

  const AttrBand(this.label);

  final String label;

  static AttrBand of(int value) {
    final v = value.clamp(0, 100);
    if (v <= 20) return minimal;
    if (v <= 40) return subtle;
    if (v <= 60) return moderate;
    if (v <= 80) return strong;
    return dominant;
  }
}

/// A choice with a label for the UI and help text for its tooltip.
abstract interface class LabelledChoice {
  String get label;
  String get help;
}

enum ResponseLength implements LabelledChoice {
  adaptive('Adaptive', 'Length follows the question.'),
  minimal('Minimal', 'One or two sentences.'),
  concise('Concise', 'A short paragraph or a few bullets.'),
  balanced('Balanced', 'A short answer and a brief reason per cue.'),
  detailed('Detailed', 'Reasons and an example per cue.'),
  comprehensive('Comprehensive', 'Reasons, examples, common mistakes and progressions.');

  const ResponseLength(this.label, this.help);
  @override
  final String label;
  @override
  final String help;
}

enum ExplanationLevel implements LabelledChoice {
  adaptive('Auto', 'Inferred from how you write.'),
  beginner('Beginner', 'Plain words; terms explained the first time.'),
  intermediate('Intermediate', 'Basic strokes and rules are known.'),
  advanced('Advanced', 'Technical terms; refinement and tactics.'),
  expert('Expert', 'Biomechanics, patterns and fine detail.');

  const ExplanationLevel(this.label, this.help);
  @override
  final String label;
  @override
  final String help;
}

enum EmojiUsage implements LabelledChoice {
  preset('Style', 'Whatever the chosen style uses.'),
  none('None', 'No emojis or emoticons.'),
  minimal('Minimal', 'At most one, only where it adds something.'),
  moderate('Moderate', 'Up to two per answer.'),
  frequent('Frequent', 'Freely, never in place of the cue.');

  const EmojiUsage(this.label, this.help);
  @override
  final String label;
  @override
  final String help;
}

enum HumorStyle implements LabelledChoice {
  adaptive('Adaptive', 'Whatever fits the style and the moment.'),
  none('None', 'No jokes at all.'),
  dry('Dry', 'Understated and deadpan.'),
  witty('Witty', 'Quick wordplay and clever observations.'),
  dark('Dark', 'Gallows humour about the grind of training, never about injury or people.'),
  wholesome('Wholesome', 'Gentle and feel-good.'),
  absurd('Absurd', 'Playful, surreal comparisons.');

  const HumorStyle(this.label, this.help);
  @override
  final String label;
  @override
  final String help;
}

enum CriticalThinking implements LabelledChoice {
  supportive('Supportive', 'Builds on your ideas; corrects gently.'),
  balanced('Balanced', 'The style decides.'),
  skeptical('Skeptical', 'Questions claims and gear myths.'),
  challenging('Challenging', 'Pushes back when the data disagrees.');

  const CriticalThinking(this.label, this.help);
  @override
  final String label;
  @override
  final String help;
}

enum Initiative implements LabelledChoice {
  reactive('Reactive', 'Answers only what you ask.'),
  balanced('Balanced', 'The style decides.'),
  proactive('Proactive', 'May point out one related thing or a next question.');

  const Initiative(this.label, this.help);
  @override
  final String label;
  @override
  final String help;
}

enum EmotionalExpression implements LabelledChoice {
  restrained('Restrained', 'Minimal emotional language.'),
  natural('Natural', 'The style decides.'),
  expressive('Expressive', 'Shows excitement and sympathy openly.');

  const EmotionalExpression(this.label, this.help);
  @override
  final String label;
  @override
  final String help;
}

T _enum<T extends Enum>(List<T> values, Object? saved, T fallback) =>
    saved is String ? (values.asNameMap()[saved] ?? fallback) : fallback;

List<String> _strings(Object? v) => v is List
    ? [
        for (final x in v)
          if (x is String && x.trim().isNotEmpty) x.trim(),
      ]
    : const [];

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

/// Languages the coach can reply in (communication-preferences.md).
const kCoachLanguages = {
  'auto': 'Same as my messages',
  'en': 'English',
  'fil': 'Filipino',
  'es': 'Spanish',
  'zh': 'Chinese',
  'ja': 'Japanese',
  'ko': 'Korean',
  'id': 'Indonesian',
  'ms': 'Malay',
  'th': 'Thai',
  'vi': 'Vietnamese',
  'hi': 'Hindi',
  'fr': 'French',
  'de': 'German',
};

const kCoachPronouns = ['they/them', 'she/her', 'he/him', 'it/its'];

/// How the coach talks, apart from its personality (communication-preferences.md).
@immutable
class CommunicationPrefs {
  const CommunicationPrefs({
    this.responseLength = ResponseLength.adaptive,
    this.explanationLevel = ExplanationLevel.adaptive,
    this.emoji = EmojiUsage.preset,
    this.humorStyle = HumorStyle.adaptive,
    this.criticalThinking = CriticalThinking.balanced,
    this.initiative = Initiative.balanced,
    this.emotionalExpression = EmotionalExpression.natural,
    this.addressByName = false,
  });

  final ResponseLength responseLength;
  final ExplanationLevel explanationLevel;
  final EmojiUsage emoji;
  final HumorStyle humorStyle;
  final CriticalThinking criticalThinking;
  final Initiative initiative;
  final EmotionalExpression emotionalExpression;
  final bool addressByName;

  bool get isDefault => this == const CommunicationPrefs();

  CommunicationPrefs copyWith({
    ResponseLength? responseLength,
    ExplanationLevel? explanationLevel,
    EmojiUsage? emoji,
    HumorStyle? humorStyle,
    CriticalThinking? criticalThinking,
    Initiative? initiative,
    EmotionalExpression? emotionalExpression,
    bool? addressByName,
  }) => CommunicationPrefs(
    responseLength: responseLength ?? this.responseLength,
    explanationLevel: explanationLevel ?? this.explanationLevel,
    emoji: emoji ?? this.emoji,
    humorStyle: humorStyle ?? this.humorStyle,
    criticalThinking: criticalThinking ?? this.criticalThinking,
    initiative: initiative ?? this.initiative,
    emotionalExpression: emotionalExpression ?? this.emotionalExpression,
    addressByName: addressByName ?? this.addressByName,
  );

  factory CommunicationPrefs.fromJson(Object? j) {
    if (j is! Map) return const CommunicationPrefs();
    return CommunicationPrefs(
      responseLength: _enum(ResponseLength.values, j['responseLength'], ResponseLength.adaptive),
      explanationLevel: _enum(
        ExplanationLevel.values,
        j['explanationLevel'],
        ExplanationLevel.adaptive,
      ),
      emoji: _enum(EmojiUsage.values, j['emoji'], EmojiUsage.preset),
      humorStyle: _enum(HumorStyle.values, j['humorStyle'], HumorStyle.adaptive),
      criticalThinking: _enum(
        CriticalThinking.values,
        j['criticalThinking'],
        CriticalThinking.balanced,
      ),
      initiative: _enum(Initiative.values, j['initiative'], Initiative.balanced),
      emotionalExpression: _enum(
        EmotionalExpression.values,
        j['emotionalExpression'],
        EmotionalExpression.natural,
      ),
      addressByName: j['addressStyle'] == 'name',
    );
  }

  Json toJson() => {
    'responseLength': responseLength.name,
    'explanationLevel': explanationLevel.name,
    'emoji': emoji.name,
    'humorStyle': humorStyle.name,
    'criticalThinking': criticalThinking.name,
    'initiative': initiative.name,
    'emotionalExpression': emotionalExpression.name,
    'addressStyle': addressByName ? 'name' : 'none',
  };

  @override
  bool operator ==(Object other) =>
      other is CommunicationPrefs &&
      other.responseLength == responseLength &&
      other.explanationLevel == explanationLevel &&
      other.emoji == emoji &&
      other.humorStyle == humorStyle &&
      other.criticalThinking == criticalThinking &&
      other.initiative == initiative &&
      other.emotionalExpression == emotionalExpression &&
      other.addressByName == addressByName;

  @override
  int get hashCode => Object.hash(
    responseLength,
    explanationLevel,
    emoji,
    humorStyle,
    criticalThinking,
    initiative,
    emotionalExpression,
    addressByName,
  );
}

/// The coach's name and pronouns, the player's nickname and the reply language. Null fields
/// fall through to the global identity, then to the defaults.
@immutable
class CoachIdentity {
  const CoachIdentity({this.coachName, this.coachPronouns, this.playerNickname, this.language});

  final String? coachName;
  final String? coachPronouns;
  final String? playerNickname;
  final String? language;

  bool get isEmpty =>
      coachName == null &&
      coachPronouns == null &&
      playerNickname == null &&
      (language == null || language == 'auto');

  /// [this] on top of [base], field by field.
  CoachIdentity over(CoachIdentity base) => CoachIdentity(
    coachName: coachName ?? base.coachName,
    coachPronouns: coachPronouns ?? base.coachPronouns,
    playerNickname: playerNickname ?? base.playerNickname,
    language: language ?? base.language,
  );

  CoachIdentity copyWith({
    String? Function()? coachName,
    String? Function()? coachPronouns,
    String? Function()? playerNickname,
    String? Function()? language,
  }) => CoachIdentity(
    coachName: coachName != null ? coachName() : this.coachName,
    coachPronouns: coachPronouns != null ? coachPronouns() : this.coachPronouns,
    playerNickname: playerNickname != null ? playerNickname() : this.playerNickname,
    language: language != null ? language() : this.language,
  );

  factory CoachIdentity.fromJson(Object? j) {
    if (j is! Map) return const CoachIdentity();
    final lang = _text(j['language']);
    final pronouns = _text(j['coachPronouns']);
    return CoachIdentity(
      coachName: _text(j['coachName']),
      coachPronouns: kCoachPronouns.contains(pronouns) ? pronouns : null,
      playerNickname: _text(j['playerNickname']),
      // 'auto' is the default: kept as null so a profile does not pin it over the global.
      language: kCoachLanguages.containsKey(lang) && lang != 'auto' ? lang : null,
    );
  }

  Json toJson() => {
    'coachName': coachName,
    'coachPronouns': coachPronouns,
    'playerNickname': playerNickname,
    'language': language ?? 'auto',
  };

  @override
  bool operator ==(Object other) =>
      other is CoachIdentity &&
      other.coachName == coachName &&
      other.coachPronouns == coachPronouns &&
      other.playerNickname == playerNickname &&
      other.language == language;

  @override
  int get hashCode => Object.hash(coachName, coachPronouns, playerNickname, language);
}

/// Words the coach should prefer or avoid, and expressions it may use now and then.
@immutable
class CoachVocabulary {
  const CoachVocabulary({
    this.preferred = const [],
    this.avoid = const [],
    this.catchphrases = const [],
  });

  final List<String> preferred;
  final List<String> avoid;
  final List<String> catchphrases;

  bool get isEmpty => preferred.isEmpty && avoid.isEmpty && catchphrases.isEmpty;

  CoachVocabulary copyWith({
    List<String>? preferred,
    List<String>? avoid,
    List<String>? catchphrases,
  }) => CoachVocabulary(
    preferred: preferred ?? this.preferred,
    avoid: avoid ?? this.avoid,
    catchphrases: catchphrases ?? this.catchphrases,
  );

  factory CoachVocabulary.fromJson(Object? j) => j is Map
      ? CoachVocabulary(
          preferred: _strings(j['preferred']),
          avoid: _strings(j['avoid']),
          catchphrases: _strings(j['catchphrases']),
        )
      : const CoachVocabulary();

  Json toJson() => {'preferred': preferred, 'avoid': avoid, 'catchphrases': catchphrases};

  @override
  bool operator ==(Object other) =>
      other is CoachVocabulary &&
      listEquals(other.preferred, preferred) &&
      listEquals(other.avoid, avoid) &&
      listEquals(other.catchphrases, catchphrases);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(preferred), Object.hashAll(avoid), Object.hashAll(catchphrases));
}

enum ProfileSource { manual, generated, imported }

/// A saved personality: a preset plus the player's changes (schema.md).
@immutable
class PersonalityProfile {
  const PersonalityProfile({
    required this.id,
    required this.name,
    required this.basePreset,
    this.overrides = const {},
    this.preferences = const CommunicationPrefs(),
    this.identity,
    this.vocabulary = const CoachVocabulary(),
    this.instructions = '',
    this.description = '',
    this.source = ProfileSource.manual,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String name;
  final String basePreset;
  final Map<PersonalityAttr, int> overrides;
  final CommunicationPrefs preferences;
  final CoachIdentity? identity;
  final CoachVocabulary vocabulary;
  final String instructions;
  final String description;
  final ProfileSource source;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  PersonalityProfile copyWith({
    String? id,
    String? name,
    String? basePreset,
    Map<PersonalityAttr, int>? overrides,
    CommunicationPrefs? preferences,
    CoachIdentity? Function()? identity,
    CoachVocabulary? vocabulary,
    String? instructions,
    String? description,
    ProfileSource? source,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => PersonalityProfile(
    id: id ?? this.id,
    name: name ?? this.name,
    basePreset: basePreset ?? this.basePreset,
    overrides: overrides ?? this.overrides,
    preferences: preferences ?? this.preferences,
    identity: identity != null ? identity() : this.identity,
    vocabulary: vocabulary ?? this.vocabulary,
    instructions: instructions ?? this.instructions,
    description: description ?? this.description,
    source: source ?? this.source,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// Null when [j] cannot be a profile (no id, name or preset).
  static PersonalityProfile? fromJson(Object? j, {Set<String>? presetIds}) {
    if (j is! Map) return null;
    final id = _text(j['id']);
    final name = _text(j['name']);
    var base = _text(j['basePreset']);
    if (id == null || name == null || base == null) return null;
    if (presetIds != null && !presetIds.contains(base)) base = 'default';
    final overrides = <PersonalityAttr, int>{};
    final raw = j['overrides'];
    if (raw is Map) {
      for (final a in PersonalityAttr.values) {
        final v = raw[a.name];
        if (v is num) overrides[a] = v.round().clamp(0, 100);
      }
    }
    return PersonalityProfile(
      id: id,
      name: name.length > 32 ? name.substring(0, 32) : name,
      basePreset: base,
      overrides: overrides,
      preferences: CommunicationPrefs.fromJson(j['preferences']),
      identity: j['identity'] is Map ? CoachIdentity.fromJson(j['identity']) : null,
      vocabulary: CoachVocabulary.fromJson(j['vocabulary']),
      instructions: j['instructions'] is String ? j['instructions'] as String : '',
      description: j['description'] is String ? j['description'] as String : '',
      source: _enum(ProfileSource.values, j['source'], ProfileSource.manual),
      createdAt: DateTime.tryParse('${j['createdAt']}'),
      updatedAt: DateTime.tryParse('${j['updatedAt']}'),
    );
  }

  Json toJson() => {
    'id': id,
    'name': name,
    'basePreset': basePreset,
    'overrides': {for (final e in overrides.entries) e.key.name: e.value},
    'preferences': preferences.toJson(),
    'identity': identity?.toJson(),
    'vocabulary': vocabulary.toJson(),
    'instructions': instructions,
    'description': description,
    'source': source.name,
    if (createdAt != null) 'createdAt': createdAt!.toUtc().toIso8601String(),
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
  };

  /// The same personality, ignoring the id, name, times and origin.
  bool sameAs(PersonalityProfile o) =>
      o.basePreset == basePreset &&
      mapEquals(o.overrides, overrides) &&
      o.preferences == preferences &&
      o.identity == identity &&
      o.vocabulary == vocabulary &&
      o.instructions == instructions &&
      o.description == description;

  @override
  bool operator ==(Object other) =>
      other is PersonalityProfile && other.id == id && other.name == name && sameAs(other);

  @override
  int get hashCode => Object.hash(id, name, basePreset, instructions);
}

/// Everything the player saved about the coach's personality (coach.personality, v1).
@immutable
class PersonalitySettings {
  const PersonalitySettings({
    this.activeId = 'preset:default',
    this.global = const CoachIdentity(),
    this.profiles = const [],
    this.readOnly = false,
    this.notice,
  });

  static const schemaVersion = 1;
  static const maxProfiles = 20;

  /// `preset:<id>` for a built-in preset with no changes, else a profile id.
  final String activeId;

  /// Name, pronouns, nickname and language shared by every profile.
  final CoachIdentity global;
  final List<PersonalityProfile> profiles;

  /// Saved by a newer app version: shown, never written.
  final bool readOnly;

  /// A one-time note for the player (the settings could not be read, and so on).
  final String? notice;

  PersonalityProfile? get activeProfile {
    for (final p in profiles) {
      if (p.id == activeId) return p;
    }
    return null;
  }

  /// The built-in preset in use: the active one, or the active profile's base.
  String get activePresetId => activeId.startsWith('preset:')
      ? activeId.substring('preset:'.length)
      : (activeProfile?.basePreset ?? 'default');

  PersonalitySettings copyWith({
    String? activeId,
    CoachIdentity? global,
    List<PersonalityProfile>? profiles,
    bool? readOnly,
    String? Function()? notice,
  }) => PersonalitySettings(
    activeId: activeId ?? this.activeId,
    global: global ?? this.global,
    profiles: profiles ?? this.profiles,
    readOnly: readOnly ?? this.readOnly,
    notice: notice != null ? notice() : this.notice,
  );

  Json toJson() => {
    'schemaVersion': schemaVersion,
    'activeProfileId': activeId,
    'global': global.toJson(),
    'profiles': [for (final p in profiles) p.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is PersonalitySettings &&
      other.activeId == activeId &&
      other.global == global &&
      listEquals(other.profiles, profiles) &&
      other.readOnly == readOnly &&
      other.notice == notice;

  @override
  int get hashCode => Object.hash(activeId, global, Object.hashAll(profiles), readOnly, notice);
}
