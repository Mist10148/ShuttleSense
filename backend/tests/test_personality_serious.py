"""Serious mode triggers: safety route, distress, explicit request, one-turn carry-over."""

from dataclasses import dataclass

import pytest

from shuttlesense.coach.personality.serious import OVERLAY, is_serious


@dataclass
class T:
    role: str
    text: str


def test_safety_route_is_serious():
    assert is_serious("safety", "what grip?")


@pytest.mark.parametrize(
    "question",
    [
        "My shoulder hurts when I smash",
        "I feel hopeless, nothing matters anymore",
        "I want to quit everything",
        "No jokes please, be serious",
        "I've been having panic attacks before matches",
    ],
)
def test_heavy_questions_are_serious(question):
    assert is_serious("knowledge", question)


@pytest.mark.parametrize(
    "question",
    ["How do I smash harder?", "I killed that rally!", "Seriously good drop shot today"],
)
def test_ordinary_questions_are_not(question):
    assert not is_serious("session", question)


def test_the_next_turn_on_the_same_topic_stays_serious():
    history = [T("user", "My knee is sore after lunges"), T("assistant", "I can't assess…")]
    assert is_serious("knowledge", "what about my footwork then?", history)
    later = [*history, T("user", "ok thanks"), T("assistant", "Sure.")]
    assert not is_serious("knowledge", "how do I serve?", later)


def test_overlay_keeps_the_professional_pointer():
    assert "no jokes" in OVERLAY and "qualified" in OVERLAY and "emergency" in OVERLAY
