"""The personality object an app sends with a chat request (docs/coach-personality/schema.md).

Lenient on style, strict on size: an unknown preset or option falls back to its default, so
a newer app still gets an answer from an older backend, but over-long text is a 422, because
cutting the player's instructions would change their meaning.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict, Field, field_validator

from shuttlesense.coach.personality import preferences as prefs
from shuttlesense.coach.personality.attributes import ORDER, Attr
from shuttlesense.coach.personality.presets import REGISTRY
from shuttlesense.coach.personality.sanitize import name_problem

_CHOICES: dict[str, tuple[set[str], str]] = {
    "responseLength": (set(prefs.LENGTH), "adaptive"),
    "explanationLevel": (set(prefs.EXPLANATION), "adaptive"),
    "emoji": (set(prefs.EMOJI), "preset"),
    "humorStyle": (set(prefs.HUMOR), "adaptive"),
    "criticalThinking": (set(prefs.CRITICAL), "balanced"),
    "initiative": (set(prefs.INITIATIVE), "balanced"),
    "emotionalExpression": (set(prefs.EMOTION), "natural"),
    "addressStyle": ({"name", "none"}, "none"),
}


class Preferences(BaseModel):
    model_config = ConfigDict(extra="ignore")

    responseLength: str = "adaptive"
    explanationLevel: str = "adaptive"
    emoji: str = "preset"
    humorStyle: str = "adaptive"
    criticalThinking: str = "balanced"
    initiative: str = "balanced"
    emotionalExpression: str = "natural"
    addressStyle: str = "none"

    @field_validator("*", mode="before")
    @classmethod
    def _known_or_default(cls, v: Any, info) -> str:
        allowed, default = _CHOICES[info.field_name]
        return v if isinstance(v, str) and v in allowed else default

    def is_default(self) -> bool:
        return all(getattr(self, k) == d for k, (_, d) in _CHOICES.items())


def _check_name(v: str | None) -> str | None:
    if v is None:
        return None
    v = v.strip()
    if not v:
        return None
    problem = name_problem(v)
    if problem:
        raise ValueError(problem)
    return v


class Identity(BaseModel):
    model_config = ConfigDict(extra="ignore")

    coachName: str | None = Field(default=None, max_length=24)
    coachPronouns: str | None = None
    playerNickname: str | None = Field(default=None, max_length=24)
    language: str = "auto"

    _names = field_validator("coachName", "playerNickname")(_check_name)

    @field_validator("coachPronouns", mode="before")
    @classmethod
    def _pronouns(cls, v: Any) -> str | None:
        return v if v in ("they/them", "she/her", "he/him", "it/its") else None

    @field_validator("language", mode="before")
    @classmethod
    def _language(cls, v: Any) -> str:
        return v if isinstance(v, str) and prefs.language_line(v) else "auto"

    def is_default(self) -> bool:
        return (
            self.coachName is None
            and self.coachPronouns is None
            and self.playerNickname is None
            and self.language == "auto"
        )


class Vocabulary(BaseModel):
    model_config = ConfigDict(extra="ignore")

    preferred: list[str] = Field(default_factory=list, max_length=20)
    avoid: list[str] = Field(default_factory=list, max_length=20)
    catchphrases: list[str] = Field(default_factory=list, max_length=5)

    @field_validator("preferred", "avoid")
    @classmethod
    def _terms(cls, v: list[str]) -> list[str]:
        if any(len(t) > 40 for t in v):
            raise ValueError("Words can be up to 40 characters.")
        return [t.strip() for t in v if t.strip()]

    @field_validator("catchphrases")
    @classmethod
    def _phrases(cls, v: list[str]) -> list[str]:
        if any(len(t) > 60 for t in v):
            raise ValueError("Expressions can be up to 60 characters.")
        return [t.strip() for t in v if t.strip()]

    def is_empty(self) -> bool:
        return not (self.preferred or self.avoid or self.catchphrases)


class PersonalityConfig(BaseModel):
    """Optional on every chat request; without it the coach is exactly as before."""

    model_config = ConfigDict(extra="ignore")

    v: int = 1
    preset: str = "default"
    overrides: dict[str, int] = Field(default_factory=dict)
    preferences: Preferences = Field(default_factory=Preferences)
    identity: Identity = Field(default_factory=Identity)
    vocabulary: Vocabulary = Field(default_factory=Vocabulary)
    instructions: str = Field(default="", max_length=1000)
    label: str = Field(default="", max_length=32)

    @field_validator("preset", mode="before")
    @classmethod
    def _preset(cls, v: Any) -> str:
        return v if isinstance(v, str) and v in REGISTRY else "default"

    @field_validator("overrides", mode="before")
    @classmethod
    def _overrides(cls, v: Any) -> dict[str, int]:
        if not isinstance(v, dict):
            return {}
        out = {}
        for k, x in v.items():
            if k in ORDER and isinstance(x, int | float) and not isinstance(x, bool):
                out[k] = max(0, min(100, int(round(x))))
        return out

    def values(self) -> dict[Attr, int]:
        """The preset's attributes with the player's changes on top."""
        base = REGISTRY[self.preset].values()
        return {a: self.overrides.get(a, base[a]) for a in ORDER}

    def is_default(self) -> bool:
        base = REGISTRY["default"].values()
        return (
            self.preset == "default"
            and all(self.overrides.get(a, base[a]) == base[a] for a in ORDER)
            and self.preferences.is_default()
            and self.identity.is_default()
            and self.vocabulary.is_empty()
            and not self.instructions.strip()
        )
