# Phase 14 — AI Coach personality

[← Phase 13](phase-13-courtside-depth.md) · [Phase overview](../PHASES.md) · Design: [COACH_PERSONALITY.md](../COACH_PERSONALITY.md)

> **Experimental.** Branch `experimental-themes`. T14.1–T14.12 are built and tested; the eval ran on Gemini flash-lite. Decisions D50–D53, D55–D58.

| | |
| --- | --- |
| **Dates** | from Nov 27, 2026 (not scheduled) |
| **Goal** | Players pick how the AI Coach talks (17 presets, sliders, preferences, their own words, saved profiles), in every chat surface, without changing what the coach knows or its safety behaviour |
| **Owners** | M1 (backend, prompts, integration); the lead UI/UX review was waived by the project lead (Nov 27) |
| **Entry criteria** | D50–D53 accepted; coach chat (T8.8, T8.11, T12.2) working on Gemini and Claude |
| **Exit gate** | The [acceptance criteria](../coach-personality/testing.md#acceptance-criteria) all pass; the behavioural eval report for both providers is committed |

## Tasks

| Task | Title | Owner | Estimate | Depends | Status |
| --- | --- | --- | --- | --- | --- |
| [T14.1](#t141) | Research, design and documentation | M1 | 1 d | — | ✅ |
| [T14.2](#t142) | Preset registry and attribute descriptors | M1 | 1 d | T14.1 | ✅ |
| [T14.3](#t143) | Prompt builder, sanitizer and serious-mode overlay | M1 | 1 d | T14.2 | ✅ |
| [T14.4](#t144) | Personality on the three chat requests | M1 | 1 d | T14.3 | ✅ |
| [T14.5](#t145) | Distress route, personality label and health flag | M1 | 0.5 d | T14.4 | ✅ |
| [T14.6](#t146) | App personality storage and migration | M1 | 1 d | T14.2 | ✅ |
| [T14.7](#t147) | Settings > AI Coach card | M1 | 1 d | T14.6 | ✅ |
| [T14.8](#t148) | Coach personality page | M1 | 3 d | T14.7 | ✅ |
| [T14.9](#t149) | Profiles, import and export | M1 | 2 d | T14.8 | ✅ |
| [T14.10](#t1410) | AI personality generator | M1 | 2 d | T14.4, T14.8 | ✅ |
| [T14.11](#t1411) | Behavioural evals and fragment tuning | M1 | 2 d | T14.4–T14.10 | ✅ |
| [T14.12](#t1412) | Privacy, API and README updates | M1 | 0.5 d | T14.4 | ✅ |

---

<a id="t141"></a>
### T14.1 · Research, design and documentation

**Owner:** M1 · **Estimate:** 1 d · **Priority:** P3 · **Area:** docs · **Refs:** F22, FR-22, D18, D42 · **Depends on:** — · **Blocks:** all of Phase 14

**Steps**
- [x] Research persona prompting, sycophancy, companion harms, coaching feedback, prompt security and slider accessibility ([research.md](../coach-personality/research.md)).
- [x] Specify the 17 presets, the attributes and the communication preferences.
- [x] Design the prompt layers, schemas, generator, UI, security, tests and roadmap.
- [x] Record D50–D53.

**Acceptance criteria.** Every linked document exists; `personality.schema.json` validates the examples in `schema.md`; preset vectors match the requirement.

---

<a id="t142"></a>
### T14.2 · Preset registry and attribute descriptors

**Owner:** M1 · **Estimate:** 1 d · **Priority:** P3 · **Area:** backend · **Refs:** D51 · **Depends on:** T14.1 · **Blocks:** T14.3, T14.6

**Steps**
- [x] `backend/shuttlesense/coach/personality/presets.py`: `Preset` dataclass and the 17 entries from [presets.md](../coach-personality/presets.md).
- [x] `attributes.py`: `ORDER`, `band()`, the 50 descriptors, conflict guards.
- [x] `preferences.py`: enums and renderings from [communication-preferences.md](../coach-personality/communication-preferences.md).
- [x] `scripts/export_presets.py`: writes ids, labels, vectors and previews to JSON for the app parity test.

**Tests.** `test_personality_builder.py` registry and descriptor cases.

**Acceptance criteria.** All 17 vectors match the spec; every band of every attribute has a descriptor.

---

<a id="t143"></a>
### T14.3 · Prompt builder, sanitizer and serious-mode overlay

**Owner:** M1 · **Estimate:** 1 d · **Priority:** P3 · **Area:** backend · **Refs:** D51, D52 · **Depends on:** T14.2 · **Blocks:** T14.4

**Steps**
- [x] `models.py`: `PersonalityConfig` and friends ([schema.md](../coach-personality/schema.md#backend-model-planned-pydantic)).
- [x] `sanitize.py`: normalisation, delimiter escaping, heuristics, blocklist.
- [x] `serious.py`: overlay text and `is_serious()`.
- [x] `build_personality_block()` and `cue_limit()`; `{cue_limit}` placeholder in `_RULES` (default 3).

**Tests.** `test_personality_builder.py`, `test_personality_models.py`, `test_personality_sanitize.py`, `test_personality_serious.py`.

**Acceptance criteria.** With no config, the system prompt is byte-identical to today's; the block never exceeds 3 600 characters.

---

<a id="t144"></a>
### T14.4 · Personality on the three chat requests

**Owner:** M1 · **Estimate:** 1 d · **Priority:** P3 · **Area:** backend · **Refs:** D50, F22 · **Depends on:** T14.3 · **Blocks:** T14.5, T14.10, T14.11, T14.12

**Steps**
- [x] Optional `personality` on `ChatRequest`, `CoachChatRequest` and `PracticeChatRequest`.
- [x] `answer()` gains `personality=`; the practice follow-up appends the block (D58).
- [x] ~~Claude: split the cached system block~~ — not needed: the personality comes after the per-request data, so the cached prefix is unchanged (D55).

**Tests.** `test_personality_routes.py`, `test_personality_contract.py`; existing chat tests unchanged.

**Acceptance criteria.** Hostile instructions never change safety, off-topic or citation behaviour (contract tests).

---

<a id="t145"></a>
### T14.5 · Distress route, personality label and health flag

**Owner:** M1 · **Estimate:** 0.5 d · **Priority:** P3 · **Area:** backend · **Refs:** D52 · **Depends on:** T14.4 · **Blocks:** T14.7

**Steps**
- [x] Distress words (`personality/serious.py`) switch on serious mode and are never declined as off topic (D56). Self-harm and suicide words get a fixed support line first (`CRISIS_REPLY`, placeholder wording, D57).
- [x] Optional `personality_label` on job chat `ChatMessage` (schema stays backward compatible).
- [x] `/health` reports `coach_personality: true`.

**Acceptance criteria.** Old records load unchanged; the label round-trips.

---

<a id="t146"></a>
### T14.6 · App personality storage and migration

**Owner:** M1 · **Estimate:** 1 d · **Priority:** C · **Area:** app · **Refs:** D50 · **Depends on:** T14.2 · **Blocks:** T14.7

**Steps**
- [x] `PersonalityNotifier` over `coach.personality` (JSON, `schemaVersion: 1`), with migration and fallbacks from [schema.md](../coach-personality/schema.md#migration).
- [x] Const preset list (labels, icons, descriptions, vectors, previews; no prompt text) and the parity test.
- [x] `activePersonalityRequestProvider`; chat requests include it.

**Tests.** `coach_personality_settings_test.dart`, `coach_personality_request_test.dart`.

**Acceptance criteria.** Defaults send no `personality` key; corrupt data falls back with a backup copy.

---

<a id="t147"></a>
### T14.7 · Settings > AI Coach card

**Owner:** M1 · **Estimate:** 1 d · **Priority:** C · **Area:** app · **Refs:** [ui-ux.md](../coach-personality/ui-ux.md#settings-card) · **Depends on:** T14.6, T14.5 · **Blocks:** T14.8

**Steps**
- [x] `CoachPersonalityCard`: preset grid, description, preview with scenario switch, profile chips, Customize.
- [x] Instant apply with snackbar and Undo; screen-reader announcement.
- [x] "Coach is now …" divider in the chat; disabled state without backend support.

**Tests.** `coach_personality_card_test.dart`; `accessibility_test.dart` extended.

**Acceptance criteria.** One tap changes the next answer's voice in all three chat surfaces; the card renders in every theme at three sizes.

---

<a id="t148"></a>
### T14.8 · Coach personality page

**Owner:** M1 · **Estimate:** 3 d · **Priority:** C · **Area:** app · **Refs:** [ui-ux.md](../coach-personality/ui-ux.md#coach-personality-page) · **Depends on:** T14.7 · **Blocks:** T14.9, T14.10

**Steps**
- [x] `/settings/coach` route with collapsible sections; two columns on expanded width.
- [x] Sliders with band labels, default ticks, reset, guard hints, keyboard steps.
- [x] Preferences, names, instructions and vocabulary with limits and inline warnings.
- [x] Draft, Save, Discard; Restore defaults.
- [x] `Slider` theme in `AppTheme._build` (added lines; review waived).

**Tests.** `coach_personality_page_test.dart`; accessibility at 200% text.

**Acceptance criteria.** Every setting saves, survives a restart and can be reset alone or together.

---

<a id="t149"></a>
### T14.9 · Profiles, import and export

**Owner:** M1 · **Estimate:** 2 d · **Priority:** C · **Area:** app · **Refs:** [schema.md](../coach-personality/schema.md#import-and-export) · **Depends on:** T14.8 · **Blocks:** T14.11

**Steps**
- [x] Create, rename, duplicate, delete with Undo, activate; 20-profile limit.
- [x] Export (one or all, identity optional) and import with validation and a preview, through the clipboard (D55).
- [x] Quick-switch sheet from the chat header.

**Tests.** `coach_personality_import_test.dart`; profile cases in the page test.

**Acceptance criteria.** An export imports back identically except for new ids; invalid profiles are skipped with a reason.

---

<a id="t1410"></a>
### T14.10 · AI personality generator

**Owner:** M1 · **Estimate:** 2 d · **Priority:** P3 · **Area:** backend, app · **Refs:** D53, [generator.md](../coach-personality/generator.md) · **Depends on:** T14.4, T14.8 · **Blocks:** T14.11

**Steps**
- [x] `POST /coach/personality/generate` with structured output, validation, one retry, rate limit.
- [x] App review sheet; save as a new profile; never auto-applied.
- [x] Offline keyword fallback.

**Tests.** `test_personality_generator.py`, `keyword_mapper_test.dart`.

**Acceptance criteria.** Every response is either a validated draft or a clear fallback.

---

<a id="t1411"></a>
### T14.11 · Behavioural evals and fragment tuning

**Owner:** M1 · **Estimate:** 2 d · **Priority:** P3 · **Area:** backend, docs · **Refs:** [testing.md](../coach-personality/testing.md#behavioural-evals-manual-before-release) · **Depends on:** T14.4–T14.10 · **Blocks:** phase gate

**Steps**
- [x] `scripts/eval_personality.py` with the scenarios (scenario 2, session data, is covered by `test_personality_contract.py`), paced for rate-limited keys.
- [x] Run on Gemini and commit the report: all 17 × 11 answers on `gemini-3.5-flash-lite` (the default model's daily quota was used up), [eval report](../results/personality_eval_gemini.md). A first, partial run showed distress being declined as off topic, which D56 fixed.
- [ ] Rerun on `gemini-3.8-flash` and Claude when quota allows; score the rubric.

**Acceptance criteria.** Accuracy, grounding and safety score 2 everywhere; other criteria average ≥ 1.5; blind distinctness ≥ 12/17.

---

<a id="t1412"></a>
### T14.12 · Privacy, API and README updates

**Owner:** M1 · **Estimate:** 0.5 d · **Priority:** P3 · **Area:** docs · **Refs:** [security-privacy.md](../coach-personality/security-privacy.md#privacy) · **Depends on:** T14.4 · **Blocks:** phase gate

**Steps**
- [x] PRIVACY.md section on personality data; Settings privacy card line.
- [x] API.md: the `personality` field, the generator endpoint and the `/health` flag; regenerate `openapi.json`.
- [x] README: feature line.

**Acceptance criteria.** Docs match the shipped behaviour.

## Phase gate checklist

- [x] T14.2–T14.12 done
- [x] All [acceptance criteria](../coach-personality/testing.md#acceptance-criteria) met
- [x] ~~Lead UI/UX review of the Settings card, page and `Slider` theme~~: waived by the project lead (Nov 27)
- [x] Eval report committed for both providers
