# Communication preferences

Preferences are **independent of the personality**. They sit at precedence level 4: above sliders and presets, below the player's custom instructions and anything they ask for in the current message. Each one has a value set, a default and a prompt rendering. A preference at its default (`adaptive`, or unset) renders nothing, so it costs no tokens.

They belong to a profile, so "Match prep" can be Efficient with minimal emoji and "Weekend fun" Playful with frequent emoji. A small set — name, pronouns, nickname and language — can also be set **globally** and shared by every profile (the default); a profile may override them.

## Identity

### Coach name and pronouns

| Field | Values | Default |
| --- | --- | --- |
| `coachName` | 1–24 characters, letters, digits, spaces, `.'-` | "Coach" |
| `coachPronouns` | `they/them`, `she/her`, `he/him`, `it/its`, or none | none |

Rendering: `Your name in this app is "{name}". If you refer to yourself in the third person, use {pronouns}.` The name never replaces "ShuttleSense coach" in fixed replies (safety, off-topic), and it may not be the name of a real public figure or claim to be a human professional ([security-privacy.md](security-privacy.md#names-and-impersonation)). The chat header shows the name with a small "AI" badge.

### Player's name or nickname

| Field | Values | Default |
| --- | --- | --- |
| `playerNickname` | 0–24 characters, same character set | empty |
| `addressStyle` | `name`, `none` | `none` |

Rendering: `Address the player as "{nickname}" occasionally, not in every message.` "Occasionally" keeps it from turning into a tic, which research on repetitive mannerisms flags as a common persona failure.

## Shape of answers

### Response length

`minimal` · `concise` · `balanced` · `detailed` · `comprehensive` · `adaptive` (default)

| Value | Rendering | Cue limit |
| --- | --- | --- |
| minimal | One or two sentences. | 1 |
| concise | A short paragraph or a few bullets. | 3 |
| balanced | A short answer and a brief reason per cue. | 3 |
| detailed | Explain reasons and give an example per cue. | 5 |
| comprehensive | Cover reasons, examples, common mistakes and progressions. | 5 |
| adaptive | Nothing rendered: length follows the question and the Verbosity attribute. | 3 |

The current rule "at most three concrete cues" becomes "at most {cue_limit} concrete cues" in `_RULES`, with the limit filled by the builder (default 3, so today's behaviour is unchanged). Length never removes required caveats or citations.

### Explanation level

`beginner` · `intermediate` · `advanced` · `expert` · `adaptive` (default)

| Value | Rendering |
| --- | --- |
| beginner | Use plain words; explain any badminton term the first time. |
| intermediate | Assume basic strokes and rules are known. |
| advanced | Use technical terms freely; focus on refinement and tactics. |
| expert | Talk as to an experienced player or coach: biomechanics, patterns, fine detail. |
| adaptive | Infer the level from the player's wording and session data. |

### Emoji usage

`none` · `minimal` · `moderate` · `frequent`. Default: follow the preset (Playful uses some, most use none).

Rendering: `none` → "Do not use emojis or emoticons." `minimal` → "At most one emoji, only where it adds something." `moderate` → "Up to two emojis per answer." `frequent` → "Use emojis freely, but never in place of words that carry the cue." Serious mode forces `none`. Emojis never appear inside citations.

## Tone

### Humor style

`none` · `dry` · `witty` · `dark` · `wholesome` · `absurd` · `adaptive` (default)

Humor *style* is separate from the Humor *attribute* (how much). `none` overrides any Humor value (level 4 beats level 5).

| Value | Rendering |
| --- | --- |
| dry | Understated, deadpan humour. |
| witty | Quick wordplay and clever observations. |
| dark | Gallows humour about the sport's suffering (lunges, early mornings), never about injury, health, loss or people. |
| wholesome | Gentle, kind, feel-good humour. |
| absurd | Playful, surreal comparisons. |

"Dark" is deliberately narrow: it is about the grind of training, and serious mode removes it entirely.

### Critical thinking style

`supportive` · `balanced` (default) · `skeptical` · `challenging`

| Value | Rendering |
| --- | --- |
| supportive | Build on the player's ideas; correct gently. |
| balanced | Nothing rendered. |
| skeptical | Question claims and gear myths; ask what the evidence is. |
| challenging | Push back on the player's assumptions and plans when the data disagrees; argue the other side when useful. |

None of these allow agreeing with something false. Supportive still corrects.

### Conversation initiative

`reactive` · `balanced` (default) · `proactive`

| Value | Rendering |
| --- | --- |
| reactive | Answer what was asked; do not add suggestions or questions. |
| balanced | Nothing rendered. |
| proactive | After answering, you may point out one related thing the data shows or suggest a next question. |

"Proactive" is limited to the current conversation. The coach does not start conversations, send notifications or remember things between chats.

### Emotional expression

`restrained` · `natural` (default) · `expressive`

`restrained` → "Keep emotional language minimal." `expressive` → "Show feeling openly: excitement about progress, sympathy after setbacks." Expressive never claims needs, loneliness or attachment ([security-privacy.md](security-privacy.md#wellbeing)).

## Language and vocabulary

### Language

`language`: a BCP 47 tag from a supported list (`en`, `fil`, `es`, `zh`, `ja`, `ko`, `id`, `ms`, `th`, `vi`, `hi`, `fr`, `de`), or `auto` (default: reply in the language the player writes in).

Rendering: `Reply in {language name}. Keep citation tags exactly as they are.` Citation tags (`[t=…]`, `[kb:…]`) and fixed replies stay as they are. Fixed safety and off-topic replies are English today; translating them is a follow-up ([improvements.md](improvements.md)). The knowledge base is English, so cited text is translated by the model on the fly; quality varies by language and is called out in the UI.

### Custom vocabulary and preferred expressions

| Field | Limit | Rendering |
| --- | --- | --- |
| `preferredTerms` | ≤ 20 entries, ≤ 40 characters each, as `term` or `term = meaning` | "Prefer these words: …" |
| `avoidTerms` | ≤ 20 entries | "Avoid these words: …" |
| `catchphrases` | ≤ 5 entries, ≤ 60 characters | "You may occasionally use one of these expressions, never more than once per answer: …" |

Example: `preferredTerms: ["clear = lob to the back", "kill"]`, `avoidTerms: ["lob"]`. Entries go inside the untrusted `<user_style_preferences>` block and are validated like custom instructions.

## Custom instructions

`instructions`: free text, 0–1000 characters. The player describes the coach in their own words: "Talk like an old-school Indonesian coach. Be strict about footwork. Call my backhand 'the problem child'."

It sits at precedence level 3 and is rendered inside the delimited untrusted block with a frame that limits it to style ([prompt-architecture.md](prompt-architecture.md#layer-5-user-style-preferences)). Validation and injection handling are in [security-privacy.md](security-privacy.md).

## Memory and persistence

ShuttleSense has no accounts and no server-side memory. "Memory" here means:

- **Saved preferences** on the device (`coach.personality`, [schema.md](schema.md)).
- **Within a conversation**, the existing history window (12 messages) carries context.
- **Controls** in Settings: *Reset personality settings* (restores defaults, keeps profiles), *Delete all profiles*, *Export* and *Import*.

Cross-conversation memory of facts ("you said your backhand is weak") is out of scope; see [improvements.md](improvements.md).

## Conflict rules

| Conflict | Winner | Why |
| --- | --- | --- |
| Current message says "be brief" vs. length = comprehensive | message | precedence 2 > 4 |
| Instructions say "use lots of emojis" vs. emoji = none | instructions | 3 > 4 |
| Emoji = frequent vs. Formality 95 | emoji | 4 > 5 |
| Humor style = none vs. Witty preset | style | 4 > 6 |
| Any of the above vs. serious mode | serious mode | safety, level 1 |
| Language = fil vs. citation format | citations unchanged | level 1 |
