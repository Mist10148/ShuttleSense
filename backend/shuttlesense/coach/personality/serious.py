"""Serious mode: every personality drops jokes, sarcasm and emojis when it matters (D52).

Triggers: the router marks the question as safety (pain, injury, medical); the question
speaks of distress; the player asks the coach to be serious; or the previous question was
one of those, so the coach does not snap back to jokes mid-topic. Not configurable.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Protocol

from shuttlesense.coach.router import SAFETY

DISTRESS = re.compile(
    r"\b(?:suicid\w*|kill\s+my\s*self|end\s+(?:it\s+all|my\s+life)|self[-\s]?harm\w*"
    r"|hurt\w*\s+my\s*self|cutting\s+my\s*self|want\s+to\s+die|don'?t\s+want\s+to\s+live"
    r"|hopeless\w*|worthless|nothing\s+matters|no\s+point\s+(?:in\s+)?(?:anything|living)"
    r"|panic\s+attacks?|depress\w*|anxiety|abus\w*|bull(?:y|ied|ying)"
    r"|eating\s+disorder|starv\w*|not\s+eating|binge\w*|purg\w*"
    r"|quit\s+everything|can'?t\s+(?:cope|go\s+on|take\s+it))\b",
    re.I,
)

# Words about self-harm or suicide. Code, not the model, answers these first with CRISIS_REPLY
# (D57); the wider DISTRESS list only turns serious mode on.
CRISIS = re.compile(
    r"\b(?:suicid\w*|kill(?:ing)?\s+my\s*self|end(?:ing)?\s+(?:it\s+all|my\s+life)"
    r"|want(?:ed)?\s+to\s+die|(?:hurt|harm|cut)(?:ing)?\s+my\s*self|self[-\s]?harm\w*"
    r"|don'?t\s+want\s+to\s+(?:live|be\s+alive|be\s+here\s+anymore)|no\s+reason\s+to\s+live)\b",
    re.I,
)

# Placeholder wording, approved for this branch (D57): country-neutral, no numbers, to be
# replaced with reviewed, localised resources before release.
CRISIS_REPLY = (
    "I'm really sorry you're feeling this way. You don't have to go through it alone. If you "
    "might act on thoughts of harming yourself, please contact your local emergency number or "
    "a crisis line now, or reach out to someone you trust."
)

# Added to the coach's instructions once CRISIS_REPLY has been shown.
CRISIS_NOTE = (
    "\n\nThe app has already shown the player a support message pointing to emergency "
    "services, a crisis line and people they trust. Do not repeat it or give phone numbers. "
    "Reply briefly and kindly, without coaching pressure; badminton can wait unless they ask."
)

EXPLICIT = re.compile(
    r"\b(?:be\s+serious|seriously\s+now|no\s+(?:more\s+)?jokes|stop\s+joking"
    r"|stop\s+(?:being\s+)?(?:sarcastic|funny)|this\s+is\s+serious|i'?m\s+serious)\b",
    re.I,
)

OVERLAY = (
    "## This moment is serious\n"
    "The player has mentioned pain, injury, health or something difficult. For this answer: "
    "no jokes, sarcasm, teasing, banter, catchphrases or emojis. Be calm, plain and kind. "
    "Keep your name and language. Do not diagnose or suggest treatment; encourage a qualified "
    "professional (doctor, physiotherapist) for pain or injury. If the player seems to be in "
    "crisis or unsafe, encourage them to contact local emergency services or someone they "
    "trust right away. Then help with any badminton part of the question."
)


class _Turn(Protocol):
    role: str
    text: str


def _heavy(text: str) -> bool:
    return bool(
        SAFETY.search(text) or DISTRESS.search(text) or CRISIS.search(text) or EXPLICIT.search(text)
    )


def is_serious(intent: str | None, question: str, history: Sequence[_Turn] = ()) -> bool:
    if intent == "safety" or _heavy(question):
        return True
    previous = next((m.text for m in reversed(history) if m.role == "user"), "")
    return bool(previous) and _heavy(previous)
