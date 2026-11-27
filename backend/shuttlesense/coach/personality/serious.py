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
    return bool(SAFETY.search(text) or DISTRESS.search(text) or EXPLICIT.search(text))


def is_serious(intent: str | None, question: str, history: Sequence[_Turn] = ()) -> bool:
    if intent == "safety" or _heavy(question):
        return True
    previous = next((m.text for m in reversed(history) if m.role == "user"), "")
    return bool(previous) and _heavy(previous)
