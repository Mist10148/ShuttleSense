import 'dart:math';

import 'personality_models.dart';
import 'presets.dart';

/// A draft personality made on the device from the player's description, when the coach is
/// offline or the AI generator fails (docs/coach-personality/generator.md, Local fallback).
class KeywordDraft {
  const KeywordDraft({required this.basePreset, required this.values, required this.matched});

  final String basePreset;

  /// All ten attributes.
  final Map<PersonalityAttr, int> values;

  /// The words that moved something, for the review sheet.
  final List<String> matched;
}

const _a = PersonalityAttr.values;

/// Word → attribute changes from the Default vector.
final Map<RegExp, Map<PersonalityAttr, int>> _rules = {
  for (final e in <String, Map<PersonalityAttr, int>>{
    r'funn(y|ier)|humou?r|jok\w*|laugh\w*': {PersonalityAttr.humor: 30},
    r'witty|clever|pun\w*': {PersonalityAttr.humor: 25, PersonalityAttr.creativity: 15},
    r'sarcas\w*|snark\w*|cynic\w*|dry': {PersonalityAttr.sarcasm: 40, PersonalityAttr.humor: 10},
    r'strict|tough|demanding|drill sergeant': {
      PersonalityAttr.assertiveness: 25,
      PersonalityAttr.directness: 15,
    },
    r'direct|blunt|straight|honest': {PersonalityAttr.directness: 20},
    r'calm|quiet|chill|relaxed|soft': {
      PersonalityAttr.enthusiasm: -25,
      PersonalityAttr.assertiveness: -10,
    },
    r'energ\w*|hype\w*|excit\w*|loud|pumped': {PersonalityAttr.enthusiasm: 30},
    r'short|brief|concise|quick|to the point': {PersonalityAttr.verbosity: -30},
    r'detail\w*|thorough|long|in.depth|explain\w*': {PersonalityAttr.verbosity: 25},
    r'gentle|kind|warm|sweet|nice': {PersonalityAttr.warmth: 20, PersonalityAttr.empathy: 15},
    r'caring|supportive|understanding|patient': {
      PersonalityAttr.empathy: 20,
      PersonalityAttr.warmth: 10,
    },
    r'cold|neutral|robot\w*|machine': {
      PersonalityAttr.warmth: -40,
      PersonalityAttr.empathy: -30,
      PersonalityAttr.humor: -30,
    },
    r'formal|professional|polite|proper': {PersonalityAttr.formality: 35},
    r'casual|chatty|friend|buddy|mate': {
      PersonalityAttr.formality: -25,
      PersonalityAttr.warmth: 10,
    },
    r'creativ\w*|imaginat\w*|fun drills|games?|metaphor\w*': {PersonalityAttr.creativity: 30},
    r'motivat\w*|push\w*|bold|confident|fierce': {
      PersonalityAttr.assertiveness: 20,
      PersonalityAttr.enthusiasm: 15,
    },
    r'shy|bashful|cute|timid': {
      PersonalityAttr.assertiveness: -25,
      PersonalityAttr.warmth: 15,
      PersonalityAttr.directness: -20,
    },
    r'serious|no.nonsense': {PersonalityAttr.humor: -30},
    r'smart|analytic\w*|scien\w*|nerd\w*|why': {
      PersonalityAttr.creativity: 10,
      PersonalityAttr.verbosity: 15,
      PersonalityAttr.formality: 10,
    },
    r'stoic|disciplin\w*|composed': {
      PersonalityAttr.enthusiasm: -20,
      PersonalityAttr.formality: 15,
      PersonalityAttr.assertiveness: 15,
    },
  }.entries)
    RegExp('\\b(?:${e.key})\\b', caseSensitive: false): e.value,
};

KeywordDraft draftFromKeywords(String description) {
  final base = presetById('default').attributes;
  final values = {for (final a in _a) a: base[a.index]};
  final matched = <String>[];
  for (final MapEntry(key: pattern, value: changes) in _rules.entries) {
    final m = pattern.firstMatch(description);
    if (m == null) continue;
    matched.add(m.group(0)!.toLowerCase());
    for (final MapEntry(key: a, value: delta) in changes.entries) {
      values[a] = (values[a]! + delta).clamp(0, 100);
    }
  }
  return KeywordDraft(basePreset: nearestPreset(values), values: values, matched: matched);
}

/// The preset whose vector is closest (Euclidean) to [values]; Custom is never chosen.
String nearestPreset(Map<PersonalityAttr, int> values) {
  var best = 'default';
  var bestDistance = double.infinity;
  for (final p in kPersonalityPresets) {
    if (p.id == 'custom') continue;
    var d = 0.0;
    for (final a in _a) {
      d += pow(values[a]! - p.attributes[a.index], 2);
    }
    if (d < bestDistance) {
      bestDistance = d;
      best = p.id;
    }
  }
  return best;
}
