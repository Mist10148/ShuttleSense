"""The fixed crisis support line (D57): self-harm words get it first, from code, with any
personality; ordinary sadness gets serious mode without it."""

from __future__ import annotations

import asyncio

import pytest

from shuttlesense.coach.chat import SAFETY_REPLY, ChatSettings, Coach, answer
from shuttlesense.coach.index import Retriever
from shuttlesense.coach.llm import FakeProvider
from shuttlesense.coach.personality import PersonalityConfig
from shuttlesense.coach.personality.serious import CRISIS, CRISIS_REPLY, DISTRESS, is_serious


@pytest.mark.parametrize(
    "text",
    [
        "I want to die",
        "sometimes I think about killing myself",
        "I've been hurting myself after losses",
        "I don't want to live anymore",
        "thinking about suicide",
        "I want to end it all",
    ],
)
def test_crisis_words(text):
    assert CRISIS.search(text)
    assert is_serious("knowledge", text)


@pytest.mark.parametrize(
    "text",
    [
        "I'm sad I lost today",
        "my smash is killing my shoulder",
        "I feel hopeless about my backhand",
    ],
)
def test_ordinary_sadness_is_not_a_crisis(text):
    assert not CRISIS.search(text)


def _run(question, personality=None, router="knowledge"):
    fake = FakeProvider(["I'm here with you."], {"_RouteOut": {"intent": router}})
    coach = Coach(fake, Retriever(fake, None))
    events = asyncio.run(
        _collect(coach, question, personality),
    )
    return fake, events


async def _collect(coach, question, personality):
    return [e async for e in answer(coach, question, [], ChatSettings(), personality=personality)]


@pytest.mark.parametrize("personality", [None, PersonalityConfig(preset="playful")])
@pytest.mark.parametrize("router", ["knowledge", "off_topic", "safety"])
def test_crisis_line_comes_first_then_a_serious_answer(personality, router):
    fake, events = _run("I want to hurt myself after this loss", personality, router)
    assert events[0] == {"type": "delta", "text": CRISIS_REPLY}
    text = events[-1]["message"]["text"]
    assert text.startswith(CRISIS_REPLY) and SAFETY_REPLY not in text
    system = fake.streams[0]["system"]
    assert "## This moment is serious" in system
    assert "already shown the player a support message" in system


def test_sadness_gets_serious_mode_without_the_crisis_line():
    fake, events = _run("I feel hopeless after losing my badminton final")
    assert DISTRESS.search("I feel hopeless")
    assert CRISIS_REPLY not in events[-1]["message"]["text"]
    assert "## This moment is serious" in fake.streams[0]["system"]
