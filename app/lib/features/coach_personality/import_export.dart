import 'dart:convert';

import 'personality_models.dart';
import 'personality_text.dart';
import 'presets.dart';

/// Personality export files (docs/coach-personality/schema.md, Import and export). Files
/// move through the clipboard, so no file-picker package is needed (D55).
const kExportFormat = 'shuttlesense.coach-personality';
const kMaxImportBytes = 64 * 1024;

String exportProfiles(List<PersonalityProfile> profiles, {CoachIdentity? global, DateTime? now}) =>
    const JsonEncoder.withIndent('  ').convert({
      'format': kExportFormat,
      'schemaVersion': PersonalitySettings.schemaVersion,
      'exportedAt': (now ?? DateTime.now()).toUtc().toIso8601String(),
      'app': 'ShuttleSense',
      if (global != null && !global.isEmpty) 'global': global.toJson(),
      'profiles': [for (final p in profiles) p.toJson()],
    });

/// What an import would add, and why anything was left out.
class ImportPreview {
  const ImportPreview({this.profiles = const [], this.skipped = const [], this.error});

  final List<PersonalityProfile> profiles;

  /// One line per profile that was left out, with the reason.
  final List<String> skipped;

  /// Set when nothing can be imported at all.
  final String? error;

  /// Profiles whose text looks like it tries to change the coach's rules (shown with a
  /// warning, still imported: the server ignores those parts).
  List<PersonalityProfile> get flagged => [
    for (final p in profiles)
      if (looksLikeRuleChange(p.instructions)) p,
  ];
}

ImportPreview previewImport(String text) {
  if (utf8.encode(text).length > kMaxImportBytes) {
    return const ImportPreview(error: 'That is too big for a personality file (64 KB at most).');
  }
  final Object? data;
  try {
    data = jsonDecode(text.trim());
  } on FormatException {
    return const ImportPreview(error: 'That is not a personality file (not JSON).');
  }
  if (data is! Map || data['format'] != kExportFormat) {
    return const ImportPreview(error: 'That is not a ShuttleSense personality file.');
  }
  final version = data['schemaVersion'];
  if (version is! int || version > PersonalitySettings.schemaVersion) {
    return const ImportPreview(
      error: 'This file was made by a newer version of ShuttleSense. Update the app first.',
    );
  }
  final raw = data['profiles'];
  if (raw is! List || raw.isEmpty) {
    return const ImportPreview(error: 'The file has no profiles.');
  }
  final profiles = <PersonalityProfile>[];
  final skipped = <String>[];
  for (final (i, r) in raw.indexed) {
    final label = r is Map && r['name'] is String ? '"${r['name']}"' : 'Profile ${i + 1}';
    final p = PersonalityProfile.fromJson(r, presetIds: kPresetIds);
    final problem = p == null ? 'it is missing its name or preset' : _problem(p);
    if (problem != null) {
      skipped.add('$label: $problem');
    } else {
      profiles.add(p!);
    }
  }
  if (profiles.length > PersonalitySettings.maxProfiles) {
    skipped.add('Only the first ${PersonalitySettings.maxProfiles} profiles can be imported.');
    profiles.removeRange(PersonalitySettings.maxProfiles, profiles.length);
  }
  return ImportPreview(profiles: profiles, skipped: skipped);
}

String? _problem(PersonalityProfile p) {
  if (p.instructions.length > kMaxInstructions) return 'its instructions are too long';
  final v = p.vocabulary;
  if (v.preferred.length > kMaxWords || v.avoid.length > kMaxWords) return 'too many words';
  if (v.catchphrases.length > kMaxPhrases) return 'too many expressions';
  if ([...v.preferred, ...v.avoid].any((w) => w.length > kMaxWord)) return 'a word is too long';
  if (v.catchphrases.any((w) => w.length > kMaxPhrase)) return 'an expression is too long';
  final id = p.identity;
  if (id?.coachName != null && nameProblem(id!.coachName!) != null) {
    return 'its coach name is not allowed';
  }
  if (id?.playerNickname != null && nameProblem(id!.playerNickname!, coach: false) != null) {
    return 'its nickname is not allowed';
  }
  return null;
}
