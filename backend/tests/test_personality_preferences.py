"""Communication preferences: defaults cost nothing, each value renders its line."""

from shuttlesense.coach.personality.preferences import cue_limit, language_line, render


def test_defaults_render_nothing():
    assert render({}) == []
    assert (
        render(
            {
                "responseLength": "adaptive",
                "explanationLevel": "adaptive",
                "emoji": "preset",
                "humorStyle": "adaptive",
                "criticalThinking": "balanced",
                "initiative": "balanced",
                "emotionalExpression": "natural",
            }
        )
        == []
    )


def test_each_preference_adds_one_line_in_order():
    lines = render({"emoji": "none", "responseLength": "minimal", "initiative": "proactive"})
    assert lines == [
        "One or two sentences.",
        "Do not use emojis or emoticons.",
        "After answering, you may point out one related thing the data shows or suggest a "
        "next question.",
    ]


def test_unknown_values_fall_back_to_nothing():
    assert render({"emoji": "lots", "humorStyle": "slapstick"}) == []


def test_humor_lines_can_be_dropped():
    assert render({"humorStyle": "dry"}) != []
    assert render({"humorStyle": "dry"}, humor_off=True) == []


def test_cue_limit_follows_response_length():
    assert cue_limit(None) == 3
    assert cue_limit("minimal") == 1
    assert cue_limit("comprehensive") == 5
    assert cue_limit("nonsense") == 3


def test_language_line():
    assert language_line("auto") == ""
    assert language_line("fil") == "Reply in Filipino. Keep citation tags exactly as they are."
    assert language_line("es-MX").startswith("Reply in Spanish")
    assert language_line("xx") == ""
