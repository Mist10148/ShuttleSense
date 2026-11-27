# AI Coach personality

> **Experimental, plan only.** This is a design for the `experimental-themes` branch. No code exists yet: the coach still has one fixed voice (`backend/shuttlesense/coach/chat.py`). Decisions: D50–D53. Implementation is tracked in [Phase 14](phases/phase-14-coach-personality.md).

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
| Practice follow-up (`POST /practice/sessions/{id}/chat`) | yes | `practice/followup.py` |
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

## Known limits

- **Persona drift.** Language models hold a persona imperfectly, especially across long chats and when the player pushes back. The design reduces drift (short prose presets, a closing reminder, tests), but cannot remove it ([research](coach-personality/research.md#persona-stability)).
- **Attributes are tendencies.** A Humor of 80 means "humour is a strong part of the voice", not "80% of sentences are jokes". The numbers are not calibrated measurements.
- **No accounts.** ShuttleSense has no user accounts, so profiles live on the device. They do not sync. Export and import cover moving them.
- **No long-term memory.** The coach does not remember facts about the player between conversations. "Memory" here means saved preferences only.
- **Provider differences.** Gemini and Claude render the same personality slightly differently. Tests check rules, not exact wording.

## References

See [research.md](coach-personality/research.md#sources) for the full list. Key sources: OWASP Top 10 for LLM Applications 2025 (LLM01, LLM07); Sharma et al., *Towards Understanding Sycophancy in Language Models* (ICLR 2024); OpenAI, *Sycophancy in GPT-4o* (2025); the PERSIST study on persona stability (AAAI); Carpentier & Mageau (2016) on change-oriented feedback in sport; WAI-ARIA APG slider pattern.
