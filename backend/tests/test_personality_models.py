"""The personality request object: lenient on style, strict on size."""

import pytest
from pydantic import ValidationError

from shuttlesense.coach.personality.models import PersonalityConfig


def test_empty_object_is_the_default():
    cfg = PersonalityConfig()
    assert cfg.preset == "default"
    assert cfg.is_default()


def test_unknown_preset_and_options_fall_back():
    cfg = PersonalityConfig.model_validate(
        {
            "preset": "pirate",
            "preferences": {"emoji": "lots", "responseLength": "concise"},
            "identity": {"coachPronouns": "xe/xem", "language": "klingon"},
            "somethingNew": 1,
        }
    )
    assert cfg.preset == "default"
    assert cfg.preferences.emoji == "preset"
    assert cfg.preferences.responseLength == "concise"
    assert cfg.identity.coachPronouns is None
    assert cfg.identity.language == "auto"


def test_overrides_are_clamped_and_unknown_attributes_dropped():
    cfg = PersonalityConfig.model_validate(
        {"preset": "bold", "overrides": {"humor": 150, "empathy": -3, "charm": 50, "warmth": True}}
    )
    assert cfg.overrides == {"humor": 100, "empathy": 0}
    assert cfg.values()["assertiveness"] == 100
    assert cfg.values()["humor"] == 100


@pytest.mark.parametrize(
    "body",
    [
        {"instructions": "x" * 1001},
        {"identity": {"coachName": "x" * 25}},
        {"identity": {"coachName": "Dr. Smith"}},
        {"vocabulary": {"preferred": ["w"] * 21}},
        {"vocabulary": {"avoid": ["x" * 41]}},
        {"vocabulary": {"catchphrases": ["x"] * 6}},
    ],
)
def test_oversized_or_disallowed_input_is_rejected(body):
    with pytest.raises(ValidationError):
        PersonalityConfig.model_validate(body)


def test_any_change_is_not_default():
    assert not PersonalityConfig(preset="witty").is_default()
    assert not PersonalityConfig(instructions="be brief").is_default()
    assert not PersonalityConfig.model_validate({"overrides": {"humor": 90}}).is_default()
    # Setting a slider to the Default preset's own value changes nothing.
    assert PersonalityConfig.model_validate({"overrides": {"humor": 50}}).is_default()
