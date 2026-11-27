"""The practice follow-up uses the coach personality (D58): the style block reaches its
prompt, the answer is labelled, the default is unchanged, and safety comes first."""

from __future__ import annotations

import asyncio
import json

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


def test_practice_route_passes_the_personality_and_labels_the_answer(monkeypatch, tmp_path):
    """The route hands the request's personality to answer() and labels the done event."""
    from shuttlesense.api import practice
    from shuttlesense.practice import followup

    seen = {}

    async def fake_answer(*args, personality=None):
        seen["personality"] = personality
        yield {"type": "done", "message": {"role": "assistant", "text": "ok", "at": "x"}}

    monkeypatch.setattr(followup, "answer", fake_answer)
    report = {**REPORT, "context_version": "a" * 64}
    monkeypatch.setattr(practice, "_completed_practice", lambda *a: (None, {"fps": 10}, 1))
    monkeypatch.setattr(practice, "_cached_practice_report", lambda *a: report)
    monkeypatch.setattr(practice, "_with_context_version", lambda *a: report)

    from fastapi.testclient import TestClient

    from shuttlesense.api.main import create_app
    from shuttlesense.api.settings import Settings

    app = create_app(Settings(storage_dir=tmp_path / "s", device="cpu", coach_provider="off"))
    with TestClient(app) as client:
        app.state.coach_provider = FakeProvider()
        body = {
            "message": "Why review this clear?",
            "context_version": "a" * 64,
            "personality": {"preset": "stoic", "label": "Calm"},
        }
        res = client.post(f"/practice/sessions/{'a' * 12}/chat", json=body)
        assert res.status_code == 200
        done = [json.loads(x[6:]) for x in res.text.splitlines() if x.startswith("data: ")][-1]
        assert done["message"]["personality_label"] == "Calm"
        assert seen["personality"].preset == "stoic"
        res = client.post(
            f"/practice/sessions/{'a' * 12}/chat",
            json={"message": "Again?", "context_version": "a" * 64},
        )
        done = [json.loads(x[6:]) for x in res.text.splitlines() if x.startswith("data: ")][-1]
        assert "personality_label" not in done["message"]
        assert seen["personality"] is None
