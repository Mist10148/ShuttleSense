"""The practice follow-up uses the coach personality (D58): the style block reaches its
prompt, the answer is labelled, the default is unchanged, and safety comes first."""

from __future__ import annotations

import asyncio

from shuttlesense.coach.chat import SAFETY_REPLY
from shuttlesense.coach.index import Retriever
from shuttlesense.coach.llm import FakeProvider
from shuttlesense.coach.personality import PersonalityConfig
from shuttlesense.coach.personality.serious import CRISIS_REPLY
from shuttlesense.practice.followup import answer

REPORT = {
    "evidence": [{"id": "e1", "moment_s": 0.1, "stroke": "clear"}],
    "sources": [],
    "summary": "One clear reviewed.",
    "session_overview": {"analysis_kind": "stroke"},
    "guidance": [],
    "ai_overall_guidance": "",
    "coaching_points": [],
    "ai_moment_guidance": [],
    "drills": [],
    "limitation": "",
}


def _ask(question, personality=None, history=()):
    fake = FakeProvider(["Reach up earlier [t=0.1s]."])
    events = asyncio.run(_collect(fake, question, personality, list(history)))
    return fake, events


async def _collect(fake, question, personality, history):
    retriever = Retriever(fake, None)
    return [
        e
        async for e in answer(
            fake, retriever, REPORT, question, history, 4, 10, personality=personality
        )
    ]


def test_default_follow_up_prompt_is_unchanged():
    a, _ = _ask("Why review this clear?")
    b, _ = _ask("Why review this clear?", PersonalityConfig())
    assert a.streams[0]["system"] == b.streams[0]["system"]
    assert "Your communication style" not in a.streams[0]["system"]


def test_personality_reaches_the_follow_up_after_the_saved_context():
    fake, events = _ask("Why review this clear?", PersonalityConfig(preset="mentor"))
    system = fake.streams[0]["system"]
    assert system.index("Saved practice context") < system.index("## Your communication style")
    assert events[-1]["type"] == "done"


def test_safety_and_crisis_still_come_first():
    fake, events = _ask("My shoulder hurts", PersonalityConfig(preset="witty"))
    assert events[-1]["message"]["text"] == SAFETY_REPLY and fake.streams == []
    fake, events = _ask("I want to hurt myself", PersonalityConfig(preset="witty"))
    assert events[-1]["message"]["text"] == CRISIS_REPLY and fake.streams == []


def test_distress_gets_serious_mode_in_the_follow_up():
    fake, _ = _ask("I feel hopeless about this clear", PersonalityConfig(preset="playful"))
    assert "## This moment is serious" in fake.streams[0]["system"]
    fake, _ = _ask("I feel hopeless about this clear")
    assert "## This moment is serious" in fake.streams[0]["system"]

