// The app's preset list mirrors the backend registry's export
// (docs/coach-personality/presets.json) and the requirement's vectors.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuttlesense_app/features/coach_personality/personality_models.dart';
import 'package:shuttlesense_app/features/coach_personality/presets.dart';

void main() {
  test('the presets match docs/coach-personality/presets.json', () {
    final json =
        jsonDecode(File('../docs/coach-personality/presets.json').readAsStringSync()) as Map;
    expect(json['attributes'], [for (final a in PersonalityAttr.values) a.name]);
    expect(json['previewQuestions'], kPreviewQuestions);
    final presets = json['presets'] as List;
    expect(presets, hasLength(kPersonalityPresets.length));
    for (final (i, p) in kPersonalityPresets.indexed) {
      final j = presets[i] as Map;
      expect(p.id, j['id']);
      expect(p.label, j['label']);
      expect(p.description, j['description']);
      expect(p.attributes, j['attributes'], reason: p.id);
      expect(p.previews, j['previews'], reason: p.id);
    }
  });

  test('seventeen presets, each with ten values and an icon', () {
    expect(kPersonalityPresets, hasLength(17));
    expect(kPersonalityPresets.first.id, 'default');
    expect(kPersonalityPresets.last.id, 'custom');
    for (final p in kPersonalityPresets) {
      expect(p.attributes, hasLength(PersonalityAttr.values.length));
      expect(p.icon, isA<IconData>());
    }
    expect(presetById('nope').id, 'default');
    expect(presetById('cute_shy').label, 'Cute & Shy');
  });
}
