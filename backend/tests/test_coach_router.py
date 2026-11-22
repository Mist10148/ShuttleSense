"""Coach intent routing: keywords, the model call and its fallback."""

from __future__ import annotations

import asyncio

import pytest

from shuttlesense.coach.llm import ChatError, FakeProvider
from shuttlesense.coach.router import keyword_route, route


@pytest.mark.parametrize(
    ("question", "job_bound", "intent"),
    [
        ("Why did my smash land short in rally 3?", True, "session"),
        ("Am I improving over my last sessions?", True, "history"),
        ("What drills fix a shallow lunge?", False, "drills"),
        ("How do I rotate in doubles?", False, "knowledge"),
        ("Is a serve above the waist a fault?", False, "knowledge"),
        ("My knee hurts after lunges, what is it?", True, "safety"),
        ("Can you write me a poem about the stock market today?", False, "off_topic"),
        ("And my clears?", True, "session"),
        ("clears", False, "knowledge"),
    ],
)
def test_keyword_routes(question: str, job_bound: bool, intent: str) -> None:
    assert keyword_route(question, job_bound=job_bound).intent == intent


def test_safety_notes_a_technique_part() -> None:
    assert keyword_route("My shoulder is sore, how do I smash?", job_bound=False).also_technique
    assert not keyword_route("my ankle is swollen", job_bound=False).also_technique


def test_model_routes_and_keywords_back_it_up() -> None:
    fake = FakeProvider(json_responses={"_RouteOut": {"intent": "drills"}})
    r = asyncio.run(route("what should I work on", fake, job_bound=True))
    assert r.intent == "drills" and r.source == "model"
    assert fake.json_calls[0]["schema"] == "_RouteOut"
    # Injury keywords win over the model.
    r = asyncio.run(route("my wrist hurts when I smash", fake, job_bound=True))
    assert r.intent == "safety"
    # No session open: the model's "session" becomes knowledge.
    fake = FakeProvider(json_responses={"_RouteOut": {"intent": "session"}})
    assert asyncio.run(route("smash tips", fake, job_bound=False)).intent == "knowledge"


def test_keywords_when_the_call_fails_or_no_provider() -> None:
    broken = FakeProvider(json_responses={"_RouteOut": ChatError("down", 503)})
    r = asyncio.run(route("Am I getting better?", broken, job_bound=True))
    assert r.intent == "history" and r.source == "keywords"
    assert asyncio.run(route("drills for net shots", None, job_bound=False)).intent == "drills"
