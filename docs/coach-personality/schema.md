# Schemas

Three shapes: what the app **stores**, what it **sends** with a chat request, and what the generator **returns**. The JSON Schema for the stored document and export file is [personality.schema.json](personality.schema.json).

## Stored document (app, v1)

Saved in `shared_preferences` under the key `coach.personality` as one JSON string, read synchronously in the notifier's `build()` like `ui.skin` (`app/lib/core/theme/app_skin.dart`).

```json
{
  "schemaVersion": 1,
  "activeProfileId": "p_7f3a9k2x",
  "global": {
    "coachName": "Coach",
    "coachPronouns": null,
    "playerNickname": "",
    "language": "auto"
  },
  "profiles": [
    {
      "id": "p_7f3a9k2x",
      "name": "Footwork bootcamp",
      "basePreset": "bold",
      "overrides": { "empathy": 60, "verbosity": 30 },
      "preferences": {
        "responseLength": "concise",
        "explanationLevel": "adaptive",
        "emoji": "none",
        "humorStyle": "adaptive",
        "criticalThinking": "challenging",
        "initiative": "proactive",
        "emotionalExpression": "natural",
        "addressStyle": "name"
      },
      "identity": null,
      "vocabulary": { "preferred": ["kill"], "avoid": [], "catchphrases": [] },
      "instructions": "Be strict about footwork.",
      "description": "Bold, but kinder and shorter.",
      "source": "manual",
      "createdAt": "2026-11-27T10:00:00Z",
      "updatedAt": "2026-11-27T10:05:00Z"
    }
  ]
}
```

| Field | Rule |
| --- | --- |
| `schemaVersion` | integer; current `1` |
| `activeProfileId` | a profile id, or a **built-in id** (`"preset:witty"`) when the player picked a preset with no changes |
| `global` | identity and language shared by profiles; a profile's `identity` object overrides it field by field |
| `profiles` | 0–20 entries |
| `id` | `p_` + 8 random base-36 characters; unique |
| `name` | 1–32 characters, unique (case-insensitive) |
| `basePreset` | one of the 17 preset ids; `custom` means "no fragment, render all descriptors" |
| `overrides` | map of attribute name → integer 0–100; absent attributes follow the preset |
| `preferences` | enums from [communication-preferences.md](communication-preferences.md); missing keys mean default |
| `vocabulary` | lists with the limits in that file |
| `instructions` | 0–1000 characters |
| `description` | 0–140 characters, shown in the picker; never sent to the backend |
| `source` | `manual`, `generated` or `imported` (for the UI badge and support) |

**Built-in presets are not stored.** Picking "Witty" with no changes saves only `activeProfileId: "preset:witty"`. The first change to a built-in creates a profile with `basePreset: "witty"` named "Witty (custom)", so built-ins can always be restored and never drift.

## Request object (app → backend)

Each chat request (job chat, general coach, practice follow-up) carries the **resolved** active personality. The app merges global and profile identity before sending, so the backend never needs the whole document.

```json
{
  "message": "Why do my smashes go into the net?",
  "history": [],
  "personality": {
    "v": 1,
    "preset": "bold",
    "overrides": { "empathy": 60, "verbosity": 30 },
    "preferences": { "responseLength": "concise", "emoji": "none", "criticalThinking": "challenging", "initiative": "proactive" },
    "identity": { "coachName": "Kai", "coachPronouns": "they/them", "playerNickname": "Mo", "language": "auto" },
    "vocabulary": { "preferred": ["kill"], "avoid": [], "catchphrases": [] },
    "instructions": "Be strict about footwork.",
    "label": "Footwork bootcamp"
  }
}
```

`personality` is optional and omitted for Default with no changes, so the request matches today's byte for byte. `label` is display only (stored on job chat messages); it never enters the prompt.

### Backend model (planned, pydantic)

```python
Attr = Literal["warmth", "humor", "sarcasm", "formality", "enthusiasm",
               "directness", "empathy", "creativity", "assertiveness", "verbosity"]

class Identity(BaseModel):
    coachName: str | None = Field(None, max_length=24, pattern=NAME_RE)
    coachPronouns: Literal["they/them", "she/her", "he/him", "it/its"] | None = None
    playerNickname: str | None = Field(None, max_length=24, pattern=NAME_RE)
    language: str = Field("auto", pattern=r"^(auto|[a-z]{2,3}(-[A-Za-z0-9]{2,8})?)$")

class Vocabulary(BaseModel):
    preferred: list[constr(max_length=40)] = Field(default_factory=list, max_length=20)
    avoid: list[constr(max_length=40)] = Field(default_factory=list, max_length=20)
    catchphrases: list[constr(max_length=60)] = Field(default_factory=list, max_length=5)

class PersonalityConfig(BaseModel):
    model_config = ConfigDict(extra="ignore")
    v: int = 1
    preset: str = "default"                 # unknown → "default" (validator)
    overrides: dict[Attr, conint(ge=0, le=100)] = {}
    preferences: Preferences = Preferences()  # enums; unknown values → default
    identity: Identity = Identity()
    vocabulary: Vocabulary = Vocabulary()
    instructions: constr(max_length=1000) = ""
    label: constr(max_length=32) = ""
```

**Lenient on style, strict on size.** An unknown preset or enum value falls back to the default (a newer app talking to an older backend still gets an answer). Over-long strings or lists return **422** with a clear message, because silently cutting the player's instructions would change their meaning. Out-of-range numbers are rejected by the app before sending and clamped by the backend if they arrive anyway.

### App model (planned, Dart)

```dart
@immutable
class PersonalityProfile {
  final String id, name, basePreset, instructions, description;
  final Map<PersonalityAttr, int> overrides;
  final CommunicationPrefs preferences;
  final CoachIdentity? identity;
  final CoachVocabulary vocabulary;
  final ProfileSource source;
  final DateTime createdAt, updatedAt;
  // fromJson / toJson / copyWith / ==
}

class PersonalityNotifier extends Notifier<PersonalitySettings> { … }
final personalityProvider = NotifierProvider<PersonalityNotifier, PersonalitySettings>(…);
final activePersonalityRequestProvider = Provider<Map<String, Object?>?>(…); // what chat sends
```

Enums are stored by `.name` and read back with `values.asNameMap()[saved] ?? fallback`, the same pattern as `AppSkin` and `StickerStrength`.

## Generator I/O

Request (`POST /coach/personality/generate`):

```json
{ "description": "A calm older coach who is strict about footwork and uses a little dry humour", "basePreset": null }
```

Response (validated before it leaves the server):

```json
{
  "name": "Quiet Taskmaster",
  "description": "Calm and strict about footwork, with dry humour.",
  "basePreset": "stoic",
  "attributes": { "warmth": 45, "humor": 35, "sarcasm": 30, "formality": 60, "enthusiasm": 20,
                  "directness": 85, "empathy": 55, "creativity": 45, "assertiveness": 85, "verbosity": 40 },
  "preferences": { "humorStyle": "dry", "emoji": "none" },
  "instructions": "Be strict about footwork and correct it first. Keep humour dry and rare.",
  "notes": ["'Older' was read as calm and experienced; age is not part of the style."]
}
```

The app turns it into a draft profile (`source: "generated"`): `attributes` become `overrides` against `basePreset`, and only values that differ are kept. See [generator.md](generator.md).

## Versioning

| Thing | Version field | Bumped when |
| --- | --- | --- |
| Stored document | `schemaVersion` | a field is renamed, removed or changes meaning |
| Request object | `personality.v` | the backend must interpret a field differently |
| Export file | `schemaVersion` (same as stored) | as stored |
| Preset registry | not versioned; ids are permanent | — |

Adding an optional field does **not** bump a version: readers ignore unknown keys and fill missing ones with defaults.

## Migration

The app migrates on load, the same idea as the backend's `schema.migrate()` for clip records (D19):

```text
load coach.personality
  ├─ missing                → defaults (activeProfileId = "preset:default"), nothing written
  ├─ not valid JSON         → keep a copy under coach.personality.corrupt, use defaults, show a one-time notice
  ├─ schemaVersion > known  → read-only mode: use what can be read, do not write, show "made by a newer version"
  └─ schemaVersion < known  → run migrations v→v+1 in order, write back, keep the old copy under coach.personality.v{n}
then, per profile:
  basePreset unknown        → "default", and a note on the profile ("Preset no longer available")
  override key unknown      → dropped
  value out of range        → clamped 0–100
  enum value unknown        → that preference reset to its default
  duplicate id or name      → id regenerated / name suffixed " (2)"
activeProfileId dangling    → "preset:default"
```

Each step is a pure function `Map → Map` with a unit test that feeds the previous version's fixture.

**Backend.** The backend stores no profiles. The only persisted personality data is the optional `personality_label` on job chat messages in `record.json`. It is added as an optional field (default `null`), so existing records need no migration and older apps ignore it.

## Import and export

**Export** writes a `.json` file in the `exportFile` shape: one profile, or all of them, with or without the global identity (a checkbox, off by default, because it contains the player's nickname). On web it downloads; on mobile and desktop it uses the platform share or save dialog.

```json
{
  "format": "shuttlesense.coach-personality",
  "schemaVersion": 1,
  "exportedAt": "2026-11-27T10:00:00Z",
  "app": "ShuttleSense 1.x",
  "profiles": [ { "id": "p_7f3a9k2x", "name": "Footwork bootcamp", "basePreset": "bold", "…": "…" } ]
}
```

**Import** (file picker or paste):

1. Reject files over 64 KB or that are not JSON.
2. Check `format` and `schemaVersion`; migrate older versions as above; refuse newer ones with a clear message.
3. Validate every profile against the schema; invalid profiles are listed with the reason and skipped, valid ones continue.
4. Run the same text checks as the editor ([security-privacy.md](security-privacy.md#sanitization)) on names, vocabulary and instructions. Profiles that trip the injection heuristics are imported **with a warning badge**, not silently.
5. Regenerate ids, suffix clashing names, set `source: "imported"`.
6. Show a preview list ("3 profiles will be added") before anything is saved. Import never changes the active profile.

Import is local only: nothing is sent to the backend until the profile is used in a chat.
