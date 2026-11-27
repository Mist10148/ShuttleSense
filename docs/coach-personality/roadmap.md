# Implementation roadmap

The work is split into phases that can each be merged on their own. Every phase leaves the app working, and the coach sounds exactly as it does today until a player picks something. The task cards live in [Phase 14](../phases/phase-14-coach-personality.md). This page shows the order, the dependencies and the risks.

```text
P0 builder + registry ──► P1 backend plumbing ──► P2 app storage + Settings card ──► P3 customization page
         │                        │                                                       │
         │                        └──────────────► P5 generator ◄─────────────────────────┤
         │                                                                                ▼
         └──────────────────────────────────────────────────────────────────────► P4 profiles, import/export
                                                                                          │
                                                                           P6 evals, live preview, polish
```

| Phase | Scope | Depends on | Estimate | Merge risk |
| --- | --- | --- | --- | --- |
| **P0 · Builder and registry** | `coach/personality/` package: presets (17 fragments), attributes and descriptors, preferences, sanitizer, serious overlay, `build_personality_block`; `{cue_limit}` in `_RULES`; unit and contract tests | — | 2 d | low: pure functions, nothing wired |
| **P1 · Backend plumbing** | optional `personality` on the three chat requests; pass into `answer()` and the practice follow-up; serious detection and the `distress` router label; `personality_label` on job chat messages; `/health` flag; split cached system block for Claude; API.md and PRIVACY.md | P0 | 1.5 d | medium: touches `chat.py`, routes and schema |
| **P2 · App storage and Settings card** | `PersonalityNotifier` and the `coach.personality` document with migration; const preset list (no prompts) and parity test; `CoachPersonalityCard` with grid, preview and snackbar/Undo; requests include the resolved personality; chat divider "Coach is now …" | P1 (for an end-to-end check; the UI can land behind the `/health` check first) | 2 d | low: new files plus one line in `SettingsScreen` |
| **P3 · Customization page** | `/settings/coach` route; sliders with semantics and keyboard; preferences; names; instructions and vocabulary with inline warnings; draft/save/discard; reset controls; `Slider` theme from tactile tokens | P2 | 3 d | medium: one theme-builder line, which needs the lead UI/UX review |
| **P4 · Profiles, import and export** | create, rename, duplicate, delete, activate; 20 limit; export and import with validation and preview; quick switcher sheet in the chat header | P3 | 2 d | low |
| **P5 · Generator** | `POST /coach/personality/generate`; prompt, validation, retry, rate limit; app review sheet; local keyword fallback | P1, P3 | 2 d | low: new endpoint |
| **P6 · Evals and polish** | `scripts/eval_personality.py`, results for Gemini and Claude, fragment tuning; optional live preview ("Try this voice": one generated sample answer, rate-limited); the crisis support line once its wording is approved; localisation of fixed replies | P1–P5 | 2–3 d | low |

About 15 working days for one developer. P0–P2 alone (about 5.5 days) deliver the core value: pick a preset in one tap.

## Dependencies and owners

| Dependency | Needed by | Note |
| --- | --- | --- |
| Lead UI/UX review (Limpin) | P2, P3 | new Settings card and `Slider` theme line in `AppTheme._build` (same rule as D49) |
| Coach owner review | P0, P1 | `_RULES` gains a placeholder; `answer()` signature changes |
| Approved crisis-support wording and resources | P6 (distress line) | a team decision with care; until then distress triggers serious mode only |
| A file save/share package (e.g. `file_saver` or `share_plus`) | P4 | check licence and platforms in TECH_STACK.md |
| Provider structured output | P5 | already used by `coach/report.py` |

## Risks

| Risk | Likelihood | Impact | Mitigation |
| --- | --- | --- | --- |
| Presets sound alike on a given model | medium | feature feels shallow | blind distinctness check in evals; tune fragments in P6 |
| Persona leaks into accuracy (e.g. Efficient drops caveats) | medium | wrong advice | contract tests and rubric; rules first; caveat requirement in the shared frame |
| Injection via custom instructions | medium | rule bypass in text | code-level safety unchanged; delimiter, sanitizer and contract tests |
| Drift in long chats | high | inconsistent voice | closing reminder; 12-message window; eval scenario 12 |
| Repetitive mannerisms (Cute & Shy's "Um…", Witty's puns) | medium | annoying | "vary your phrasing" line; frequency words ("now and then"); eval criterion |
| Players treat warm personas as companions | low–medium | wellbeing | no dependency cues; serious mode; visible AI badge |
| Bigger prompt, higher cost | low | cost | ≤ ~900 tokens; caching split |
| App and backend versions mismatch | medium | choice silently ignored | optional field plus `/health` flag and pill |

## What is deliberately left out

- Server-side profiles or sync: there are no accounts (see [improvements.md](improvements.md)).
- Personality in coach reports and practice reports: they stay neutral.
- Voice (text-to-speech) personalities.
- Per-conversation personality pinning: the active profile applies everywhere. It is a possible P6 extension.
