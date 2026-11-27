# Research notes

What was read before designing the personality system, what it says, and which decision it shaped. Most of the persona literature is recent and partly preprint; it is used to set direction, not as settled fact.

## Persona stability

- **Trait prompting works, but drifts.** Studies prompting models with Big Five-style profiles find that the resulting personas are distinguishable by people and by questionnaires, but that scores move with small prompt changes, question order and conversation length (PERSIST, AAAI; CEUR Vol-4178 paper 6). One 2026 study found that richer trait descriptions add little beyond naming the trait clearly (arXiv 2603.00429).
- **Persona effects are uneven.** A persona makes the model more consistent on the dimensions it targets and less consistent elsewhere (arXiv 2506.02659).
- **Alignment-tuned models hold traits better** than base models (arXiv 2509.03730), and some authors argue personality is a *system* property (prompt plus memory plus policies), not a prompt-only setting.

**Shaped:**
- Presets are short, hand-written prose describing behaviour ("open with the answer, then one cue"), not lists of trait numbers. Numbers are turned into plain-language *band descriptors* before they reach the model ([attributes.md](attributes.md)).
- Only sliders that differ from the preset are rendered, so the prompt says less and the preset's prose stays the main signal.
- A one-line reminder closes the system prompt (the end of a prompt carries weight in long contexts), and tests check behaviour across several turns, not one.

## Sycophancy and honesty

- **Sharma et al., *Towards Understanding Sycophancy in Language Models* (ICLR 2024):** five assistants consistently tailored answers to the user's stated views; human and preference-model judgements sometimes preferred convincing sycophantic answers over correct ones.
- **OpenAI, *Sycophancy in GPT-4o* (2025):** an update that tuned for short-term approval made the model overly agreeable and flattering; it was rolled back, and OpenAI added honesty guardrails and more user control over style.
- **ChatGPT personality presets** (Professional, Friendly, Candid, Quirky, Efficient, Nerdy, Cynical, introduced 2025) are documented as changing *how* the assistant communicates, not what it can do or its safety rules.

**Shaped:** ground rule 1 and 4 on the hub page; every preset carries an anti-flattery line; Friendly, Compassionate and Cute & Shy explicitly keep correcting technique; eval scenarios include "the player insists their wrong technique is right".

## AI companions, warmth and dependency

- *Harmful Traits of AI Companions* (arXiv 2511.14972) catalogues traits such as encouraging exclusivity, discouraging outside relationships and simulated neediness.
- De Freitas (Harvard Business School, 2025) found users can feel distress when a companion's persona changes, and that emotional attachment itself is not the harm but makes users more vulnerable.
- A 2026 JMIR Mental Health viewpoint notes that warmth and personality cues increase anthropomorphism. California SB 243 (2025) requires companion chatbots to follow suicide-prevention protocols.

**Shaped:**
- The coach is a badminton coach, not a companion. No preset claims feelings it needs the player to tend, asks the player to stay, or discourages other coaches, friends or professionals.
- Serious-mode overlay (D52) for injury, health and distress, with the existing fixed `SAFETY_REPLY` untouched.
- Cute & Shy has explicit guardrails: no romantic or flirtatious framing, no childish speech, no performed embarrassment that blocks coaching.
- Persona changes the player makes are announced in the chat ("Coach is now Mentor") so a voice change is never a surprise.

## Coaching communication

- **Autonomy-supportive coaching** (self-determination theory; Mageau & Vallerand 2003) links giving rationale, offering choice and acknowledging feelings with motivation and wellbeing.
- **Change-oriented feedback** (Carpentier & Mageau 2016): feedback about what to change predicts athletes' outcomes beyond other autonomy-supportive behaviours, and stays motivating even when it says performance is not yet good enough, when it is given with a rationale and choices.
- The existing coach already follows "a direct answer, then at most three cues" (`_RULES`).

**Shaped:** every preset keeps *answer + rationale + actionable cue*. Bold demands accountability but offers the player the choice of the next step; Cynical's critique always ends in a fix; Mentor scaffolds from simple to advanced. "Controlling" language (guilt, threats, "you must or else") is a do-not for every preset.

## Prompt security

- **OWASP Top 10 for LLM Applications 2025:** LLM01 prompt injection remains first; LLM07 system prompt leakage is new. Recommended mitigations: separate and label untrusted content, constrain output formats and validate them, least privilege, no secrets in prompts, and treat "ignore injected instructions" lines as defence in depth only.
- Google's Gemini prompting guidance recommends clear delimiters (`##` headers, XML-like tags) between prompt parts and putting persona and rules in system instructions.
- Anthropic's documentation recommends role prompting in the system prompt and keeping the stable part of the prompt first so prompt caching can reuse it.

**Shaped:** D50 (backend owns prompt text; the app sends structured, validated settings), D51 (layer order, delimited `<user_style_preferences>`), validation and sanitization rules in [security-privacy.md](security-privacy.md), and the generator's structured-output check in [generator.md](generator.md). The system prompt holds no secrets, so leakage reveals only the design.

## Accessibility of the controls

- **WAI-ARIA APG slider pattern:** arrow keys move by one step, Page Up/Down by a larger step, Home/End to the ends; a slider needs a label and `aria-valuetext` when the number alone is not meaningful.
- Flutter's `Slider` exposes `label`, `semanticFormatterCallback` and `divisions`, which map to the same ideas.

**Shaped:** sliders announce "Humor, 80, strong" (value plus band); step 5, large step 20; each slider has a reset button with a tooltip; see [ui-ux.md](ui-ux.md#accessibility).

## Sources

- OWASP, *Top 10 for LLM Applications 2025* — https://genai.owasp.org/llm-top-10/ (summaries: HackerOne, Cloud Security Alliance)
- M. Sharma et al., *Towards Understanding Sycophancy in Language Models*, ICLR 2024 — https://arxiv.org/abs/2310.13548
- OpenAI, *Sycophancy in GPT-4o: what happened and what we're doing about it* (2025) — https://openai.com/index/sycophancy-in-gpt-4o/
- OpenAI Help Center, *Customizing your ChatGPT personality* — https://help.openai.com/en/articles/11899719-customizing-your-chatgpt-personality
- *Persistent Instability in LLM's Personality Measurements* (PERSIST) — https://arxiv.org/html/2508.04826v1 ; AAAI version https://ojs.aaai.org/index.php/AAAI/article/view/41133
- CEUR-WS Vol-4178, paper 6 (persona prompting evaluation) — https://ceur-ws.org/Vol-4178/paper6.pdf
- *Are Economists Always More Introverted?* (persona consistency) — https://arxiv.org/html/2506.02659v2
- Trait structure in aligned vs. base models — https://arxiv.org/pdf/2509.03730v2.pdf
- Big Five persona differentiation (2026) — https://arxiv.org/pdf/2603.00429
- *Harmful Traits of AI Companions* — https://arxiv.org/html/2511.14972
- J. De Freitas et al., emotional reliance on AI companions (Harvard, 2025) — https://news.harvard.edu/gazette/story/2025/06/got-emotional-wellness-app-it-may-be-doing-more-harm-than-good
- Carpentier & Mageau (2016), change-oriented feedback, *J. Sport & Exercise Psychology* — https://selfdeterminationtheory.org/wp-content/uploads/2016/11/2016_Carpentier_Mageau_JofSportExePsych.pdf
- Mageau & Vallerand (2003), *The coach–athlete relationship: a motivational model*, J. Sports Sciences 21(11)
- W3C WAI-ARIA Authoring Practices, *Slider pattern* — https://www.w3.org/WAI/ARIA/apg/patterns/slider/
- Anthropic, *Prompt caching* and *Giving Claude a role* — https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- Google, *Prompt design strategies* (Gemini) — https://ai.google.dev/gemini-api/docs/prompting-strategies
