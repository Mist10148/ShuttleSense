# AI Coach personality

> **Experimental, built.** This lives on the `experimental-themes` branch and needs a review from the lead UI/UX developer (the Settings card, the personality page, the slider theme) before it is merged. Decisions: D50–D53, D55, D56. Progress is tracked in [Phase 14](phases/phase-14-coach-personality.md); [what was built](#what-was-built) lists where the code is and what differs from the design.

ShuttleSense's coach answers questions about a recorded session (job chat), about progress and general badminton (the general coach), and about a saved practice video (practice follow-up). Today every answer comes in the same voice. This page plans a **personality system**: the player picks how the coach talks in **Settings > AI Coach**, from 17 presets, and can fine-tune it with sliders, communication preferences and their own words.

A personality changes **how** the coach says things. It never changes **what** the coach knows, which data it may use, how it cites, or what it refuses.

| Preset | In one line |
| --- | --- |
| Default | Balanced, adaptable, conversational |
| Professional | Formal, precise, objective |
| Friendly | Warm, approachable, optimistic |
| Efficient | Direct and concise, no filler |
| Intellectual | Analytical, curious, challenges assumptions |
| Mentor | Patient, educational, progressive |
| Witty | Clever humour and wordplay |
| Cynical | Dry, sharp, sceptical, helpful underneath |
| Compassionate | Gentle, attentive, reassuring |
| Creative | Imaginative drills, metaphors, new angles |
| Bold | Confident, demanding, accountable |
| Reserved | Calm, quiet, restrained |
| Robotic | Literal, systematic, numbers first |
| Playful | Energetic banter and challenges |
| Stoic | Composed, focuses on what you control |
| Cute & Shy | Sweet and bashful, still a sharp coach |
| Custom | Built from the player's own sliders and words |

## Ground rules

1. **Style, not substance.** Every personality shares the same rules, data, retrieval, citation checks and safety replies. A personality may make an answer shorter, warmer or funnier. It may not make it less accurate, drop a needed caveat ("speeds are 2D estimates"), invent a number or skip a citation.
2. **Safety outranks style.** Injury, pain, health or emotional distress switches every personality to a calm, plain, caring register (the *serious-mode overlay*, D52). Sarcasm, teasing, jokes and emojis stop. The fixed injury reply (`SAFETY_REPLY`) is never rephrased.
3. **The player's words are data.** Custom instructions, the coach's name, nicknames and vocabulary are untrusted text. They are validated, length-limited and placed in a delimited block that can only shape tone. They cannot add rules, change data access or reveal the prompt (D50, D51).
4. **No flattery, no dependency.** No personality agrees just to please, praises weak play as strong, or encourages the player to rely on the coach emotionally. Warm presets stay honest; caring presets point to people when it matters.
5. **One prompt, many voices.** The base coach prompt is written once. A personality adds a short block on top. Presets are data in one registry, not 17 copies of the system prompt.
6. **Changing voice keeps the conversation.** Switching personality applies from the next answer. History is not cleared, and saved replies keep the personality they were written in.
7. **Works in every theme.** The settings UI is built from the existing tactile kit (`SectionCard`, `KeyCap`, `DepthSegmented`, `TactileSwitchTile`) and holds the same contrast, touch target and text-scaling rules as the rest of Settings.

## Scope

| Surface | Personality applies | Where it is built |
| --- | --- | --- |
| Job chat (`POST /jobs/{id}/chat`) | yes | `coach/chat.py` `answer()` |
| General coach (`POST /coach/chat`) | yes | `coach/chat.py` `answer()` |
| Practice follow-up (`POST /practice/sessions/{id}/chat`) | not yet: its code belongs to another developer; the request already accepts the field and ignores it | `practice/followup.py` |
| Coach report, practice report (JSON) | no: reports stay neutral | `coach/report.py`, `practice/report.py` |
| Fixed replies (safety, off-topic, side question, refusal) | no: fixed wording | `coach/chat.py` constants |
| Router (`coach/router.py`) | no | — |

Reports are structured artefacts that are saved, compared and exported, so they keep one voice. A later phase may let a personality phrase the report's *summary sentence* only ([roadmap](coach-personality/roadmap.md)).

## Precedence

When instructions conflict, the higher one wins:

1. Core application rules: accuracy, data grounding, citations, safety, privacy, authorization.
2. Explicit communication requests in the player's current message ("just give me the numbers").
3. Custom personality instructions (the player's own words).
4. Communication preferences (response length, emoji use, humour style …).
5. Manually adjusted attributes (sliders).
6. The selected preset.
7. Default behaviour.

Levels 3–7 are style only. Level 2 can also only change style; a message asking the coach to drop the rules is still bound by level 1. See [prompt architecture](coach-personality/prompt-architecture.md#precedence).

## Architecture at a glance

```text
 App (Flutter)                                Backend (FastAPI)
 ─────────────                                ─────────────────
 Settings > AI Coach                           chat routes (job, general, practice)
   │ PersonalityNotifier (Riverpod)              │ PersonalityConfig (pydantic, validated,
   │ saved as coach.personality (JSON, v1)       │   clamped, unknown → Default)
   ▼                                             ▼
 chat request ── { message, history,  ───────► build_personality_block(config, context)
                   personality: {...} }          │  preset prose (registry)
                                                 │  + attribute band descriptors (overrides only)
                                                 │  + communication preferences
                                                 │  + <user_style_preferences> (untrusted, delimited)
                                                 │  + serious-mode overlay when needed
                                                 ▼
                                          system = core rules + surface prompt + data
                                                   + personality block + precedence reminder
                                                 ▼
                                          provider.stream(...) → validate citations → SSE
```

The app stores profiles and preferences. The backend owns every word of trusted prompt text and turns a validated, structured config into prose. The app never sends prompt text that the backend trusts.

## Documents

| Document | What it covers |
| --- | --- |
| [research.md](coach-personality/research.md) | Findings, sources and the decisions they shaped |
| [presets.md](coach-personality/presets.md) | The 17 presets: description, icon, traits, attributes and prompt fragment |
| [attributes.md](coach-personality/attributes.md) | The 10 attributes, intensity bands and how sliders become prompt text |
| [communication-preferences.md](coach-personality/communication-preferences.md) | Name, pronouns, nickname, length, explanation level, emoji, humour, language and more |
| [prompt-architecture.md](coach-personality/prompt-architecture.md) | Prompt layers, precedence, the builder, serious mode, token budget, caching |
| [schema.md](coach-personality/schema.md) · [personality.schema.json](coach-personality/personality.schema.json) | Storage and request schemas, validation, versioning, migration, import and export |
| [generator.md](coach-personality/generator.md) | The AI-assisted personality generator |
| [ui-ux.md](coach-personality/ui-ux.md) | Settings card, customization page, wireframes, states, accessibility |
| [security-privacy.md](coach-personality/security-privacy.md) | Trust boundary, prompt injection, output validation, privacy, wellbeing |
| [testing.md](coach-personality/testing.md) | Unit, widget, accessibility and prompt evaluation tests; acceptance criteria |
| [roadmap.md](coach-personality/roadmap.md) | Phased implementation, dependencies, estimates and risks |
| [improvements.md](coach-personality/improvements.md) | Related improvements found while inspecting the repository |

## What was built

**Backend** (`backend/shuttlesense/coach/personality/`):

| File | What it holds |
| --- | --- |
| `attributes.py` | the ten attributes, bands, the 50 descriptors and the guards |
| `presets.py` | the 17 presets: fragments, serious notes, sample replies |
| `preferences.py` | communication preferences, their lines and the cue limit |
| `sanitize.py` | cleaning and checking the player's text and names |
| `serious.py` | the serious overlay and its triggers |
| `models.py` | `PersonalityConfig`, the validated request object |
| `__init__.py` | `build_personality_block`, `label_for`, `cue_limit` |
| `generator.py` | the AI draft, its validation and retry |

`coach/chat.py` `answer()` takes `personality=`; `POST /jobs/{id}/chat` and `POST /coach/chat` accept it, and the answer carries `personality_label` (saved on job chat messages). `POST /coach/personality/generate` drafts one. `/health` reports `coach_personality`. `scripts/export_presets.py` writes [presets.json](coach-personality/presets.json) for the app, and `scripts/eval_personality.py` runs the scenario eval.

**App** (`app/lib/features/coach_personality/`): the models, the preset list, `PersonalityNotifier` (saved as `coach.personality`), the text hints, the offline keyword drafter, import and export, the chat's quick switcher, and the page `/settings/coach` with its sections in `widgets/`. The Settings card is `features/settings/widgets/coach_personality_card.dart`. The general coach shows "Coach is now …" when the voice changes mid-conversation.

**What differs from the design:**
- **Practice follow-up:** not wired yet (see Scope).
- **Prompt caching:** the Claude system block was not split. The personality comes after the per-request data, so the cached prefix behaves exactly as before (D55).
- **Import and export:** through the clipboard and a text dialog, so no file-picker package was added (D55).
- **Distress:** a message in distress is never declined as off topic, and gets the serious overlay with or without a personality (D56). The fixed support line still waits for approved wording.
- **Save** sits in a bar pinned under the page rather than in its header, so it stays in reach.

**Tests:** `backend/tests/test_personality_*.py` (attributes, presets, preferences, sanitize, serious, models, builder, contract, routes, generator) and `app/test/` `personality_models_test`, `personality_presets_test`, `personality_text_test`, `coach_personality_settings_test`, `coach_personality_import_test`, `coach_personality_request_test`, `coach_personality_page_test`, `coach_personality_card_test`, plus the page in `accessibility_test`.

## Known limits

- **Persona drift.** Language models hold a persona imperfectly, especially across long chats and when the player pushes back. The design reduces drift (short prose presets, a closing reminder, tests), but cannot remove it ([research](coach-personality/research.md#persona-stability)).
- **Attributes are tendencies.** A Humor of 80 means "humour is a strong part of the voice", not "80% of sentences are jokes". The numbers are not calibrated measurements.
- **No accounts.** ShuttleSense has no user accounts, so profiles live on the device. They do not sync. Export and import cover moving them.
- **No long-term memory.** The coach does not remember facts about the player between conversations. "Memory" here means saved preferences only.
- **Provider differences.** Gemini and Claude render the same personality slightly differently. Tests check rules, not exact wording.
- **Not yet evaluated on a live model.** The scenario eval was started on Gemini, but the key's quota ran out; it is the open part of T14.11.

## References

See [research.md](coach-personality/research.md#sources) for the full list. Key sources: OWASP Top 10 for LLM Applications 2025 (LLM01, LLM07); Sharma et al., *Towards Understanding Sycophancy in Language Models* (ICLR 2024); OpenAI, *Sycophancy in GPT-4o* (2025); the PERSIST study on persona stability (AAAI); Carpentier & Mageau (2016) on change-oriented feedback in sport; WAI-ARIA APG slider pattern.
