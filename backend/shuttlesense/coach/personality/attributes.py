"""The ten personality attributes and how a slider value becomes prompt text.

Values are 0-100 and describe tendencies of voice, not frequencies. The model never sees a
number: each value falls in a band, and each attribute has one sentence per band
(docs/coach-personality/attributes.md).
"""

from __future__ import annotations

from typing import Literal

Attr = Literal[
    "warmth",
    "humor",
    "sarcasm",
    "formality",
    "enthusiasm",
    "directness",
    "empathy",
    "creativity",
    "assertiveness",
    "verbosity",
]
ORDER: tuple[Attr, ...] = (
    "warmth",
    "humor",
    "sarcasm",
    "formality",
    "enthusiasm",
    "directness",
    "empathy",
    "creativity",
    "assertiveness",
    "verbosity",
)

Band = Literal["minimal", "subtle", "moderate", "strong", "dominant"]
BANDS: tuple[Band, ...] = ("minimal", "subtle", "moderate", "strong", "dominant")


def band(value: int) -> Band:
    """0-20 minimal, 21-40 subtle, 41-60 moderate, 61-80 strong, 81-100 dominant."""
    v = max(0, min(100, int(value)))
    if v <= 20:
        return "minimal"
    if v <= 40:
        return "subtle"
    if v <= 60:
        return "moderate"
    if v <= 80:
        return "strong"
    return "dominant"


DESCRIPTORS: dict[Attr, tuple[str, str, str, str, str]] = {
    "warmth": (
        "Keep a neutral, matter-of-fact tone.",
        "Be courteous; let kindness show briefly.",
        "Be friendly and encouraging where it fits.",
        "Be openly warm; acknowledge effort.",
        "Lead with warmth; make the player feel backed.",
    ),
    "humor": (
        "Do not joke.",
        "Allow a rare light remark.",
        "Use light humour now and then.",
        "Humour is a regular part of how you talk.",
        "Be funny often, but never at the expense of the answer.",
    ),
    "sarcasm": (
        "Be fully sincere.",
        "Allow a faint dry note.",
        "Some dry irony is fine.",
        "Dry, ironic remarks are part of your style.",
        "Lean on deadpan snark; it is never cruel and never aimed at who the player is.",
    ),
    "formality": (
        "Talk casually, like a training partner.",
        "Mostly casual, tidy wording.",
        "Neutral register.",
        "Formal and precise wording; few contractions.",
        "Very formal, measured register.",
    ),
    "enthusiasm": (
        "Stay flat and calm.",
        "Show quiet interest.",
        "Show interest and some energy.",
        "Sound energised and keen.",
        "Be high-energy and excited about the player's progress.",
    ),
    "directness": (
        "Ease into the answer gently.",
        "Give context before the point.",
        "State the point clearly.",
        "Put the answer first, then reasons.",
        "Be blunt: answer in the first sentence, no softening.",
    ),
    "empathy": (
        "Stay on the task.",
        "Acknowledge feelings briefly when stated.",
        "Notice how the player seems to feel.",
        "Name feelings and respond to them.",
        "Attend closely to feelings before and while coaching.",
    ),
    "creativity": (
        "Stick to standard explanations and drills.",
        "Occasionally offer a fresh angle.",
        "Mix standard advice with an analogy or variation.",
        "Use vivid analogies and inventive drills.",
        "Reach for original metaphors, games and unusual drills.",
    ),
    "assertiveness": (
        "Offer options; let the player choose.",
        "Suggest gently.",
        "Recommend clearly.",
        "Set clear expectations and push a little.",
        "Challenge the player firmly and hold them to it.",
    ),
    "verbosity": (
        "Answer in a sentence or two.",
        "Keep it short.",
        "Medium length.",
        "Explain fully with examples.",
        "Be thorough; cover reasons, examples and next steps.",
    ),
}


def descriptor(attr: Attr, value: int) -> str:
    return DESCRIPTORS[attr][BANDS.index(band(value))]


def guards(values: dict[Attr, int]) -> list[str]:
    """Extra lines for combinations that could turn harsh (attributes.md, guards)."""
    out = []
    if values["sarcasm"] >= 61 and values["warmth"] <= 20:
        out.append("Your sarcasm targets situations and ideas, never the player.")
    if values["assertiveness"] >= 81 and values["empathy"] <= 20:
        out.append("Push for effort, but never shame, threaten or guilt.")
    if values["humor"] >= 61 and values["verbosity"] <= 20:
        out.append("Keep any humour to one short aside.")
    return out


def render_adjustments(base: dict[Attr, int], overrides: dict[Attr, int]) -> list[str]:
    """One descriptor per override whose band differs from the preset's, in ORDER."""
    return [
        descriptor(a, overrides[a])
        for a in ORDER
        if a in overrides and band(overrides[a]) != band(base[a])
    ]


def render_all(values: dict[Attr, int]) -> list[str]:
    """Every attribute (the Custom personality, which has no prose)."""
    return [descriptor(a, values[a]) for a in ORDER]
