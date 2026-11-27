import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/server_config.dart';
import '../../data/models/json.dart';
import 'personality_models.dart';
import 'presets.dart';

/// The coach personality settings, saved on the device as one JSON document
/// (`coach.personality`, docs/coach-personality/schema.md). Reads are synchronous, like the
/// theme; every change sets the state first and then writes.
class PersonalityNotifier extends Notifier<PersonalitySettings> {
  static const key = 'coach.personality';

  final _random = Random();

  @override
  PersonalitySettings build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(key);
    if (raw == null) return const PersonalitySettings();
    final Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      // Keep what could not be read, start again, and tell the player once.
      prefs.setString('$key.corrupt', raw);
      prefs.remove(key);
      return const PersonalitySettings(
        notice: 'Coach settings were reset because they could not be read.',
      );
    }
    return migrate(data);
  }

  /// Reads a saved document of any version this app knows (schema.md, Migration).
  static PersonalitySettings migrate(Object? data) {
    if (data is! Map) return const PersonalitySettings();
    final version = data['schemaVersion'];
    final readOnly = version is int && version > PersonalitySettings.schemaVersion;
    final profiles = <PersonalityProfile>[];
    final ids = <String>{};
    final names = <String>{};
    for (final raw in data['profiles'] is List ? data['profiles'] as List : const []) {
      var p = PersonalityProfile.fromJson(raw, presetIds: kPresetIds);
      if (p == null || profiles.length >= PersonalitySettings.maxProfiles) continue;
      if (!ids.add(p.id)) p = p.copyWith(id: _newId(Random()));
      ids.add(p.id);
      p = p.copyWith(name: _unique(p.name, names));
      names.add(p.name.toLowerCase());
      profiles.add(p);
    }
    var active = data['activeProfileId'] is String
        ? data['activeProfileId'] as String
        : 'preset:default';
    final validPreset =
        active.startsWith('preset:') && kPresetIds.contains(active.substring('preset:'.length));
    if (!validPreset && !profiles.any((p) => p.id == active)) active = 'preset:default';
    return PersonalitySettings(
      activeId: active,
      global: CoachIdentity.fromJson(data['global']),
      profiles: profiles,
      readOnly: readOnly,
      notice: readOnly
          ? 'These settings were made by a newer version of ShuttleSense. Changes are off.'
          : null,
    );
  }

  static String _newId(Random r) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return 'p_${List.generate(8, (_) => chars[r.nextInt(chars.length)]).join()}';
  }

  /// [name], or [name] (2), (3)… if another profile already has it (case-insensitive).
  static String _unique(String name, Set<String> taken) {
    if (!taken.contains(name.toLowerCase())) return name;
    for (var i = 2; ; i++) {
      final suffix = ' ($i)';
      final base = name.length + suffix.length > 32 ? name.substring(0, 32 - suffix.length) : name;
      final candidate = '$base$suffix';
      if (!taken.contains(candidate.toLowerCase())) return candidate;
    }
  }

  String newId() {
    final taken = {for (final p in state.profiles) p.id};
    while (true) {
      final id = _newId(_random);
      if (!taken.contains(id)) return id;
    }
  }

  String uniqueName(String name, {String? except}) => _unique(name, {
    for (final p in state.profiles)
      if (p.id != except) p.name.toLowerCase(),
  });

  Future<void> _save(PersonalitySettings next) async {
    if (state.readOnly) return;
    state = next;
    await ref.read(sharedPreferencesProvider).setString(key, jsonEncode(next.toJson()));
  }

  void clearNotice() {
    if (state.notice != null) state = state.copyWith(notice: () => null);
  }

  /// Uses a built-in preset as it is.
  Future<void> activatePreset(String id) =>
      _save(state.copyWith(activeId: 'preset:${presetById(id).id}'));

  Future<void> activateProfile(String id) async {
    if (state.profiles.any((p) => p.id == id)) await _save(state.copyWith(activeId: id));
  }

  /// Activates whatever [activeId] names (a preset or a profile), e.g. to undo a change.
  Future<void> activate(String activeId) => activeId.startsWith('preset:')
      ? activatePreset(activeId.substring('preset:'.length))
      : activateProfile(activeId);

  /// Adds [profile] or replaces the one with its id; [activate] makes it the coach's.
  Future<PersonalityProfile?> saveProfile(
    PersonalityProfile profile, {
    bool activate = false,
  }) async {
    if (state.readOnly) return null;
    final now = DateTime.now().toUtc();
    final exists = state.profiles.any((p) => p.id == profile.id);
    if (!exists && state.profiles.length >= PersonalitySettings.maxProfiles) return null;
    final saved = profile.copyWith(
      name: uniqueName(
        profile.name.trim().isEmpty ? 'My coach' : profile.name.trim(),
        except: profile.id,
      ),
      createdAt: profile.createdAt ?? now,
      updatedAt: now,
    );
    final profiles = exists
        ? [for (final p in state.profiles) p.id == saved.id ? saved : p]
        : [...state.profiles, saved];
    await _save(state.copyWith(profiles: profiles, activeId: activate ? saved.id : null));
    return saved;
  }

  /// A new profile starting from [basePreset], or from [from] (a copy of it).
  PersonalityProfile draftFrom({String? basePreset, PersonalityProfile? from, String? name}) {
    if (from != null) {
      return from.copyWith(
        id: newId(),
        name: uniqueName(name ?? '${from.name} (copy)'),
        source: ProfileSource.manual,
      );
    }
    final preset = presetById(basePreset ?? 'default');
    return PersonalityProfile(
      id: newId(),
      name: uniqueName(name ?? '${preset.label} (custom)'),
      basePreset: preset.id,
    );
  }

  Future<void> rename(String id, String name) async {
    final p = state.profiles.where((p) => p.id == id).firstOrNull;
    if (p == null || name.trim().isEmpty) return;
    await saveProfile(p.copyWith(name: name.trim()));
  }

  Future<PersonalityProfile?> duplicate(String id) async {
    final p = state.profiles.where((p) => p.id == id).firstOrNull;
    if (p == null) return null;
    return saveProfile(draftFrom(from: p));
  }

  /// Removes a profile and returns what is needed to undo it. Deleting the active profile
  /// makes its base preset active.
  Future<(PersonalityProfile, int, String)?> delete(String id) async {
    final index = state.profiles.indexWhere((p) => p.id == id);
    if (index < 0 || state.readOnly) return null;
    final removed = state.profiles[index];
    final wasActive = state.activeId;
    await _save(
      state.copyWith(
        profiles: [...state.profiles]..removeAt(index),
        activeId: wasActive == id ? 'preset:${removed.basePreset}' : null,
      ),
    );
    return (removed, index, wasActive);
  }

  Future<void> undoDelete((PersonalityProfile, int, String) removed) async {
    final (profile, index, active) = removed;
    if (state.profiles.any((p) => p.id == profile.id)) return;
    final profiles = [...state.profiles]..insert(index.clamp(0, state.profiles.length), profile);
    await _save(state.copyWith(profiles: profiles, activeId: active));
  }

  /// Clears a profile's changes, keeping its name and base preset.
  Future<void> restoreDefaults(String id) async {
    final p = state.profiles.where((p) => p.id == id).firstOrNull;
    if (p == null) return;
    await saveProfile(
      PersonalityProfile(
        id: p.id,
        name: p.name,
        basePreset: p.basePreset,
        source: p.source,
        createdAt: p.createdAt,
      ),
    );
  }

  Future<void> setGlobal(CoachIdentity identity) => _save(state.copyWith(global: identity));

  /// Adds imported profiles with fresh ids and unique names; never changes the active one.
  Future<int> addProfiles(List<PersonalityProfile> incoming) async {
    if (state.readOnly) return 0;
    final profiles = [...state.profiles];
    final names = {for (final p in profiles) p.name.toLowerCase()};
    var added = 0;
    for (final p in incoming) {
      if (profiles.length >= PersonalitySettings.maxProfiles) break;
      final name = _unique(p.name, names);
      names.add(name.toLowerCase());
      profiles.add(p.copyWith(id: newId(), name: name, source: ProfileSource.imported));
      added++;
    }
    await _save(state.copyWith(profiles: profiles));
    return added;
  }

  /// Back to the Default coach with no profiles and no names.
  Future<void> resetAll() => _save(const PersonalitySettings());
}

final personalityProvider = NotifierProvider<PersonalityNotifier, PersonalitySettings>(
  PersonalityNotifier.new,
);

/// The effective identity of [settings]' active personality.
CoachIdentity effectiveIdentity(PersonalitySettings settings) =>
    (settings.activeProfile?.identity ?? const CoachIdentity()).over(settings.global);

/// What a chat request carries (schema.md, Request object), or null for the Default coach
/// with nothing changed, so the request is exactly as before.
Json? personalityRequest(PersonalitySettings s) {
  final profile = s.activeProfile;
  final identity = effectiveIdentity(s);
  final preset = s.activePresetId;
  if (profile == null && preset == 'default' && identity.isEmpty) return null;
  final base = presetById(preset).attributes;
  final overrides = <String, int>{
    if (profile != null)
      for (final e in profile.overrides.entries)
        if (base[e.key.index] != e.value) e.key.name: e.value,
  };
  return {
    'v': 1,
    'preset': preset,
    'overrides': overrides,
    'preferences': (profile?.preferences ?? const CommunicationPrefs()).toJson(),
    'identity': identity.toJson(),
    'vocabulary': (profile?.vocabulary ?? const CoachVocabulary()).toJson(),
    'instructions': profile?.instructions ?? '',
    'label': profile?.name ?? presetById(preset).label,
  };
}

/// The personality to send with the next chat question.
final activePersonalityRequestProvider = Provider<Json?>(
  (ref) => personalityRequest(ref.watch(personalityProvider)),
);

/// The name the chat shows for the active personality.
final activePersonalityLabelProvider = Provider<String>((ref) {
  final s = ref.watch(personalityProvider);
  return s.activeProfile?.name ?? presetById(s.activePresetId).label;
});
