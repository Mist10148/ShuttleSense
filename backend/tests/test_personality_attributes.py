"""Personality attributes: bands, descriptors, guards and override rendering."""

from shuttlesense.coach.personality.attributes import (
    BANDS,
    DESCRIPTORS,
    ORDER,
    band,
    descriptor,
    guards,
    render_adjustments,
    render_all,
)


def test_bands_follow_the_documented_ranges():
    assert [band(v) for v in (0, 20, 21, 40, 41, 60, 61, 80, 81, 100)] == [
        "minimal", "minimal", "subtle", "subtle", "moderate",
        "moderate", "strong", "strong", "dominant", "dominant",
    ]  # fmt: skip
    assert band(-5) == "minimal"
    assert band(150) == "dominant"


def test_every_attribute_has_one_sentence_per_band():
    assert set(DESCRIPTORS) == set(ORDER)
    for attr in ORDER:
        assert len(DESCRIPTORS[attr]) == len(BANDS)
        assert all(s.endswith(".") for s in DESCRIPTORS[attr])
    assert descriptor("humor", 70) == "Humour is a regular part of how you talk."


def test_only_overrides_that_change_band_are_rendered():
    base = dict.fromkeys(ORDER, 50)
    assert render_adjustments(base, {"humor": 55}) == []
    assert render_adjustments(base, {"humor": 70, "verbosity": 10}) == [
        "Humour is a regular part of how you talk.",
        "Answer in a sentence or two.",
    ]


def test_custom_renders_all_ten_in_order():
    lines = render_all(dict.fromkeys(ORDER, 50))
    assert len(lines) == 10
    assert lines[0] == descriptor("warmth", 50)


def test_guards_soften_harsh_combinations():
    v = dict.fromkeys(ORDER, 50)
    assert guards(v) == []
    harsh = {**v, "sarcasm": 90, "warmth": 10, "assertiveness": 95, "empathy": 5}
    text = " ".join(guards(harsh))
    assert "never the player" in text
    assert "never shame" in text
