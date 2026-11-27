"""Communication preferences and the prompt line each one adds.

A preference at its default renders nothing, so it costs no tokens
(docs/coach-personality/communication-preferences.md). Conflicts with the preset and the
sliders are settled here, in code, before anything reaches the model.
"""

from __future__ import annotations

from typing import Literal

ResponseLength = Literal["minimal", "concise", "balanced", "detailed", "comprehensive", "adaptive"]
ExplanationLevel = Literal["beginner", "intermediate", "advanced", "expert", "adaptive"]
Emoji = Literal["none", "minimal", "moderate", "frequent", "preset"]
HumorStyle = Literal["none", "dry", "witty", "dark", "wholesome", "absurd", "adaptive"]
CriticalThinking = Literal["supportive", "balanced", "skeptical", "challenging"]
Initiative = Literal["reactive", "balanced", "proactive"]
EmotionalExpression = Literal["restrained", "natural", "expressive"]
AddressStyle = Literal["name", "none"]

LENGTH = {
    "minimal": ("One or two sentences.", 1),
    "concise": ("A short paragraph or a few bullets.", 3),
    "balanced": ("A short answer and a brief reason per cue.", 3),
    "detailed": ("Explain reasons and give an example per cue.", 5),
    "comprehensive": ("Cover reasons, examples, common mistakes and progressions.", 5),
    "adaptive": ("", 3),
}

EXPLANATION = {
    "beginner": "Use plain words; explain any badminton term the first time.",
    "intermediate": "Assume basic strokes and rules are known.",
    "advanced": "Use technical terms freely; focus on refinement and tactics.",
    "expert": ("Talk as to an experienced player or coach: biomechanics, patterns, fine detail."),
    "adaptive": "",
}

EMOJI = {
    "none": "Do not use emojis or emoticons.",
    "minimal": "At most one emoji, only where it adds something.",
    "moderate": "Up to two emojis per answer.",
    "frequent": "Use emojis freely, but never in place of words that carry the cue.",
    "preset": "",
}

HUMOR = {
    "none": "Do not joke.",
    "dry": "When you use humour, keep it understated and deadpan.",
    "witty": "When you use humour, make it quick wordplay and clever observations.",
    "dark": (
        "When you use humour, gallows humour about the grind of training (lunges, early "
        "mornings) is fine; never about injury, health, loss or people."
    ),
    "wholesome": "When you use humour, keep it gentle, kind and feel-good.",
    "absurd": "When you use humour, playful, surreal comparisons are fine.",
    "adaptive": "",
}

CRITICAL = {
    "supportive": "Build on the player's ideas; correct gently.",
    "balanced": "",
    "skeptical": "Question claims and gear myths; ask what the evidence is.",
    "challenging": (
        "Push back on the player's assumptions and plans when the data disagrees; argue the "
        "other side when useful."
    ),
}

INITIATIVE = {
    "reactive": "Answer what was asked; do not add suggestions or questions.",
    "balanced": "",
    "proactive": (
        "After answering, you may point out one related thing the data shows or suggest a "
        "next question."
    ),
}

EMOTION = {
    "restrained": "Keep emotional language minimal.",
    "natural": "",
    "expressive": (
        "Show feeling openly: excitement about progress, sympathy after setbacks. Never "
        "claim needs, loneliness or attachment."
    ),
}

LANGUAGES = {
    "en": "English",
    "fil": "Filipino",
    "es": "Spanish",
    "zh": "Chinese",
    "ja": "Japanese",
    "ko": "Korean",
    "id": "Indonesian",
    "ms": "Malay",
    "th": "Thai",
    "vi": "Vietnamese",
    "hi": "Hindi",
    "fr": "French",
    "de": "German",
}


def cue_limit(length: str | None) -> int:
    """How many concrete cues an answer may end with (the rules say three by default)."""
    return LENGTH.get(length or "adaptive", LENGTH["adaptive"])[1]


def language_line(code: str | None) -> str:
    if not code or code == "auto":
        return ""
    name = LANGUAGES.get(code.split("-")[0].lower())
    if name is None:
        return ""
    return f"Reply in {name}. Keep citation tags exactly as they are."


def render(prefs: dict[str, str | None], *, humor_off: bool = False) -> list[str]:
    """One line per preference that is not at its default, in a fixed order. [humor_off]
    drops humour lines (serious mode, or Humor style = none already said it)."""
    lines = [
        LENGTH.get(prefs.get("responseLength") or "adaptive", ("", 3))[0],
        EXPLANATION.get(prefs.get("explanationLevel") or "adaptive", ""),
        EMOJI.get(prefs.get("emoji") or "preset", ""),
        "" if humor_off else HUMOR.get(prefs.get("humorStyle") or "adaptive", ""),
        CRITICAL.get(prefs.get("criticalThinking") or "balanced", ""),
        INITIATIVE.get(prefs.get("initiative") or "balanced", ""),
        EMOTION.get(prefs.get("emotionalExpression") or "natural", ""),
    ]
    return [line for line in lines if line]
