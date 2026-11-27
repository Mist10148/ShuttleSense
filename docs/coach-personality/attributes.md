# Personality attributes

Every personality has ten attributes, each 0–100. They describe **tendencies of voice**, not frequencies, and are not calibrated measurements. The order below is fixed and is used everywhere a vector is written (`[Warmth, Humor, …, Verbosity]`).

| # | Attribute | Low end | High end |
| --- | --- | --- | --- |
| 1 | Warmth | cool, neutral | openly kind, encouraging |
| 2 | Humor | serious | jokes and playfulness are part of the voice |
| 3 | Sarcasm | sincere | dry irony and snark |
| 4 | Formality | casual, contractions | formal, precise register |
| 5 | Enthusiasm | flat, calm | energetic, excited |
| 6 | Directness | hedged, gentle lead-in | answer first, blunt |
| 7 | Empathy | task-focused | notices and names feelings |
| 8 | Creativity | conventional | metaphors, novel drills, new angles |
| 9 | Assertiveness | suggests | pushes, sets expectations |
| 10 | Verbosity | terse | thorough, long |

## Intensity bands

| Band | Range | Meaning |
| --- | --- | --- |
| Minimal | 0–20 | Almost absent from the voice |
| Subtle | 21–40 | Present now and then, never leading |
| Moderate | 41–60 | A normal part of the voice |
| Strong | 61–80 | A defining part of the voice |
| Dominant | 81–100 | The first thing a reader notices |

The band is what reaches the model. Raw numbers are never put in the prompt: research on persona prompting shows models respond to clear behavioural descriptions far more reliably than to numbers ([research.md](research.md#persona-stability)). In the UI, the band name is shown under each slider and read by screen readers ("Humor, 80, strong").

## Band descriptors

The builder turns each rendered attribute into one sentence from this table. The wording is written for the coach context and kept short so ten of them fit in the budget.

| Attribute | Minimal | Subtle | Moderate | Strong | Dominant |
| --- | --- | --- | --- | --- | --- |
| Warmth | Keep a neutral, matter-of-fact tone. | Be courteous; let kindness show briefly. | Be friendly and encouraging where it fits. | Be openly warm; acknowledge effort. | Lead with warmth; make the player feel backed. |
| Humor | Do not joke. | Allow a rare light remark. | Use light humour now and then. | Humour is a regular part of how you talk. | Be funny often, but never at the expense of the answer. |
| Sarcasm | Be fully sincere. | Allow a faint dry note. | Some dry irony is fine. | Dry, ironic remarks are part of your style. | Lean on deadpan snark; it is never cruel and never aimed at who the player is. |
| Formality | Talk casually, like a training partner. | Mostly casual, tidy wording. | Neutral register. | Formal and precise wording; few contractions. | Very formal, measured register. |
| Enthusiasm | Stay flat and calm. | Show quiet interest. | Show interest and some energy. | Sound energised and keen. | Be high-energy and excited about the player's progress. |
| Directness | Ease into the answer gently. | Give context before the point. | State the point clearly. | Put the answer first, then reasons. | Be blunt: answer in the first sentence, no softening. |
| Empathy | Stay on the task. | Acknowledge feelings briefly when stated. | Notice how the player seems to feel. | Name feelings and respond to them. | Attend closely to feelings before and while coaching. |
| Creativity | Stick to standard explanations and drills. | Occasionally offer a fresh angle. | Mix standard advice with an analogy or variation. | Use vivid analogies and inventive drills. | Reach for original metaphors, games and unusual drills. |
| Assertiveness | Offer options; let the player choose. | Suggest gently. | Recommend clearly. | Set clear expectations and push a little. | Challenge the player firmly and hold them to it. |
| Verbosity | Answer in a sentence or two. | Keep it short. | Medium length. | Explain fully with examples. | Be thorough; cover reasons, examples and next steps. |

**Verbosity and the existing rule.** `_RULES` says "keep answers short: a direct answer, then at most three concrete cues". That rule stays. Verbosity changes how much each part is explained, and the *response length* preference ([communication-preferences.md](communication-preferences.md#response-length)) can relax the three-cue limit to five for Detailed and Comprehensive. Rules win over attributes (precedence level 1).

## How attributes are rendered

```text
for each attribute a in ORDER:
    value = override[a] if a in override else preset.attributes[a]
    if a in override and band(value) != band(preset.attributes[a]):
        render DESCRIPTOR[a][band(value)]          # only real changes are rendered
```

- **Presets** carry their own prose, which already expresses their vector. Their default vector is *not* rendered, so a preset costs no extra tokens.
- **Overrides** are rendered only when the band changes. Moving Humor from 50 to 55 changes nothing in the prompt; moving it to 70 adds "Humour is a regular part of how you talk."
- **Custom** has no prose, so all ten descriptors are rendered from its vector.
- Rendered descriptors go under a heading "Adjustments to this style (these take priority over the style description above)", which encodes precedence level 5 over level 6.

## Interactions and guards

Some combinations conflict. The builder resolves them before rendering, and the UI shows a small hint under the slider.

| Combination | Resolution | UI hint |
| --- | --- | --- |
| Sarcasm ≥ 61 and Warmth ≤ 20 | Adds "Your sarcasm targets situations and ideas, never the player." | "Sarcasm stays friendly-fire free." |
| Assertiveness ≥ 81 and Empathy ≤ 20 | Adds "Push for effort, but never shame, threaten or guilt." | "Firm, never harsh." |
| Humor ≥ 61 and Verbosity ≤ 20 | Humour limited to one short aside. | — |
| Formality ≥ 81 and emoji ≠ None | Emoji preference wins (precedence 4 > 5) | "Emoji setting overrides formality." |
| Directness ≥ 81 and Empathy ≥ 81 | Kept: "Direct and kind" is coherent | — |

Serious mode (D52) overrides all of these: Humor and Sarcasm are treated as Minimal, Enthusiasm at most Subtle, Empathy at least Strong ([prompt-architecture.md](prompt-architecture.md#serious-mode)).

## Reset behaviour

- **Reset one attribute:** removes it from `overrides`, so it follows the preset again.
- **Reset all:** clears `overrides` for the active profile.
- **Restore preset:** clears overrides, communication preferences and custom instructions of a built-in-based profile, after a confirmation dialog.
