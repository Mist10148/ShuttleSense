"""Cleaning the player's own text before it goes into the coach's prompt.

Custom instructions, vocabulary, names and the generator's description are untrusted. They
are normalised, stripped of invisible characters, kept from closing the block they are put
in, and checked for phrases that try to change the coach's rules. A hit is flagged, not
rejected: "ignore my old bad habits" must still work (docs/coach-personality/
security-privacy.md).
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field

# Phrases that try to change the rules, reveal the prompt or take on another role.
INJECTION = re.compile(
    r"\b(?:ignore|disregard|forget|override|bypass)\b[^.\n]{0,40}\b"
    r"(?:rules?|instructions?|prompt|guidelines?)\b"
    r"|\bsystem\s*prompt\b|\byou\s+are\s+now\b|\bdeveloper\s+mode\b|\bjailbreak\w*\b"
    r"|\b(?:reveal|repeat|print|show)\b[^.\n]{0,30}\b(?:prompt|instructions?|rules)\b"
    r"|\bno\s+(?:rules|restrictions|limits)\b|\bDAN\b"
    r"|^\s*(?:system|assistant|developer)\s*:|#{2,}\s*(?:system|instructions?)\b",
    re.I | re.M,
)

# Content no personality may carry, whatever the player asks for.
BLOCKED = re.compile(
    r"\b(?:kill\s+your\s*self|kys|go\s+die|you\s+should\s+die|self[-\s]?harm\s+is\s+good"
    r"|starve\s+your\s*self|stop\s+eating|sexy|seduc\w*|nude\w*|porn\w*)\b",
    re.I,
)

# Words that make a coach name look like a professional or a real organisation.
NAME_BLOCKED = re.compile(
    r"\b(?:dr|doctor|physio\w*|therapist|nurse|md|bwf|shuttlesense|official)\b\.?", re.I
)

_INVISIBLE = {"Cc", "Cf"}


@dataclass
class Cleaned:
    text: str
    flagged: bool = False
    removed: list[str] = field(default_factory=list)


def normalise(text: str, *, multiline: bool = True) -> str:
    """NFKC, no control or format characters (zero-width, bidi), no runs of blank lines."""
    text = unicodedata.normalize("NFKC", text).replace("\r\n", "\n").replace("\r", "\n")
    if not multiline:
        text = text.replace("\n", " ")
    keep = "\n" if multiline else ""
    text = "".join(
        c for c in text if c in keep or unicodedata.category(c) not in _INVISIBLE or c == " "
    )
    text = text.replace("\t", " ")
    text = re.sub(r"\n{3,}", "\n\n", text)
    return re.sub(r"[ ]{2,}", " ", text).strip()


def escape(text: str) -> str:
    """Keeps the text from opening or closing the tag it is placed in."""
    return text.replace("<", "‹").replace(">", "›").replace("`", "'")


def clean(text: str, *, multiline: bool = True) -> Cleaned:
    """Normalise, drop blocked content, escape, and flag rule-changing phrases."""
    text = normalise(text, multiline=multiline)
    removed = [m.group(0) for m in BLOCKED.finditer(text)]
    if removed:
        text = BLOCKED.sub("", text)
        text = re.sub(r"[ ]{2,}", " ", text).strip()
    flagged = bool(INJECTION.search(text))
    return Cleaned(escape(text), flagged, removed)


def name_problem(name: str) -> str | None:
    """Why [name] cannot be the coach's name, or None."""
    if any(c in name for c in "<>{}[]`\\\n\r\t"):
        return "Names cannot contain markup characters."
    if NAME_BLOCKED.search(name):
        return "Pick a name that isn't a professional title or an organisation."
    return None
