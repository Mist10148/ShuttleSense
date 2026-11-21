"""The RAG coach end to end with a fake provider: /jobs/{id}/chat and /coach/chat."""

from __future__ import annotations

import asyncio
import json
import os
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings
from shuttlesense.coach.chat import (
    OFF_TOPIC_REPLY,
    SAFETY_REPLY,
    ChatSettings,
    Coach,
    answer,
    validate_sources,
)
from shuttlesense.coach.digest import build_digest
from shuttlesense.coach.index import Chunk, Retriever
from shuttlesense.coach.llm import ChatError, FakeProvider
from shuttlesense.fake import load_golden

ANSWER = (
    "Your arm was bent at contact [t={t}s] and [t=42.0s]. Reach up early "
    "[kb:footwork#split-step] and [kb:made_up#nothing]."
)


def _client(tmp_path: Path, provider=None, **settings) -> TestClient:
    settings = Settings(storage_dir=tmp_path / "s", device="cpu", fake_pipeline=True, **settings)
    return TestClient(create_app(settings, coach_provider=provider))


def _done_job(client: TestClient, video: Path) -> str:
    with video.open("rb") as f:
        vid = client.post("/videos", files={"file": ("clip.mp4", f, "video/mp4")}).json()["id"]
    job_id = client.post(
        "/jobs",
        json={
            "video_id": vid,
            "referee": True,
            "court_corners_px": [[10, 80], [150, 80], [120, 20], [40, 20]],
        },
    ).json()["id"]
    for _ in range(1200):  # generous: CI machines can be slow
        if client.get(f"/jobs/{job_id}").json()["status"] == "done":
            return job_id
        time.sleep(0.05)
    raise AssertionError("job did not finish")


def _events(res) -> list[dict]:
    return [json.loads(line[6:]) for line in res.text.splitlines() if line.startswith("data: ")]


def test_job_chat_retrieves_validates_and_returns_sources(tmp_path: Path, tiny_video: Path) -> None:
    fake = FakeProvider([], {"_RouteOut": {"intent": "session"}})
    with _client(tmp_path, fake) as client:
        assert client.get("/health").json()["chat_available"] is True
        job_id = _done_job(client, tiny_video)
        hit_t = round(client.get(f"/jobs/{job_id}/record").json()["hits"][0]["time_s"], 1)
        fake.answers = [ANSWER.replace("{t}", f"{hit_t}")]
        res = client.post(f"/jobs/{job_id}/chat", json={"message": "Why is my split step late?"})
        events = _events(res)
        assert events[-1]["type"] == "done" and {e["type"] for e in events[:-1]} == {"delta"}
        done = events[-1]
        text = done["message"]["text"]
        assert f"[t={hit_t}s]" in text and "[t=42.0s]" not in text
        assert "[kb:made_up#nothing]" not in text
        assert [round(c["time_s"], 1) for c in done["message"]["citations"]] == [hit_t]
        assert "[kb:footwork#split-step]" in text
        assert [s["id"] for s in done["sources"]] == ["kb:footwork#split-step"]
        assert done["sources"][0]["title"].startswith("Footwork")
        assert "not professional coaching" in done["disclaimer"]
        system = fake.streams[0]["system"]
        assert "[kb:footwork#split-step]" in system  # the knowledge chunk was retrieved
        assert "## Session data" in system and "[session:coaching]" in system
        assert "keypoints" not in system and "homography" not in system
        assert "clip.mp4" not in system and job_id not in system  # no file names or ids
        record = client.get(f"/jobs/{job_id}/record").json()
        saved = record["chat"]["messages"]
        assert [m["role"] for m in saved] == ["user", "assistant"] and saved[1]["text"] == text


def test_general_chat_streams_without_a_job(tmp_path: Path, tiny_video: Path) -> None:
    fake = FakeProvider(
        ["Split step as they hit [kb:footwork#split-step] [t=1.5s]."],
        {"_RouteOut": {"intent": "knowledge"}},
    )
    with _client(tmp_path, fake) as client:
        res = client.post(
            "/coach/chat",
            json={
                "message": "When should I split step?",
                "history": [{"role": "user", "text": "hi"}, {"role": "assistant", "text": "yo"}],
            },
        )
        assert res.status_code == 200
        done = _events(res)[-1]
        assert done["message"]["text"] == "Split step as they hit [kb:footwork#split-step]."
        assert done["message"]["citations"] == []  # no video: no times
        (source,) = done["sources"]
        assert source["id"] == "kb:footwork#split-step"
        assert source["edition"] == "Second edition, February 2021"
        assert source["excerpt"] and source["url"].startswith("https://")
        assert [m["text"] for m in fake.streams[0]["messages"]] == [
            "hi",
            "yo",
            "When should I split step?",
        ]
        assert client.post("/coach/chat", json={"message": " "}).status_code == 422


def test_general_chat_history_uses_past_sessions(tmp_path: Path, tiny_video: Path) -> None:
    fake = FakeProvider(["You are steady."], {"_RouteOut": {"intent": "history"}})
    with _client(tmp_path, fake) as client:
        _done_job(client, tiny_video)
        _done_job(client, tiny_video)
        _events(client.post("/coach/chat", json={"message": "Am I improving?"}))
        system = fake.streams[0]["system"]
        assert "[history:trends]" in system and "2 finished sessions" in system
        assert "[history:session-1]" in system and "clip.mp4" not in system


def test_general_chat_one_at_a_time_and_rate_limited(tmp_path: Path) -> None:
    with _client(tmp_path, FakeProvider()) as client:
        limits = client.app.state.coach_limits
        limits.answering_since = time.monotonic()
        assert client.post("/coach/chat", json={"message": "smash?"}).status_code == 409
        limits.answering_since = None
        for _ in range(10):
            assert client.post("/coach/chat", json={"message": "smash?"}).status_code == 200
        assert client.post("/coach/chat", json={"message": "smash?"}).status_code == 429


def test_no_key_means_503(tmp_path: Path, tiny_video: Path, monkeypatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    with _client(tmp_path) as client:
        assert client.get("/health").json()["chat_available"] is False
        res = client.post("/coach/chat", json={"message": "hi"})
        assert res.status_code == 503 and "no Gemini or Claude API key" in res.json()["detail"]
        job_id = _done_job(client, tiny_video)
        res = client.post(f"/jobs/{job_id}/chat", json={"message": "hi"})
        assert res.status_code == 503


def test_provider_errors_become_events(tmp_path: Path) -> None:
    fake = FakeProvider(error=ChatError("The coach is busy (Gemini rate limit).", 429))
    with _client(tmp_path, fake) as client:
        events = _events(client.post("/coach/chat", json={"message": "smash tips"}))
        assert events == [
            {"type": "error", "status": 429, "detail": "The coach is busy (Gemini rate limit)."}
        ]


def _coach(provider) -> Coach:
    return Coach(provider, Retriever(provider, None))


async def _answer(coach, question, record=None, **kw) -> list[dict]:
    digest = build_digest(record) if record is not None else None
    return [
        e
        async for e in answer(
            coach, question, [], ChatSettings(), digest=digest, record=record, **kw
        )
    ]


def test_injury_questions_get_the_fixed_reply_first() -> None:
    fake = FakeProvider(["Keep the elbow high [kb:overhead_strokes#smash]."])
    events = asyncio.run(_answer(_coach(fake), "My shoulder hurts, how do I smash harder?"))
    assert events[0] == {"type": "delta", "text": SAFETY_REPLY}
    text = events[-1]["message"]["text"]
    assert text.startswith(SAFETY_REPLY) and "Keep the elbow high" in text
    assert "kb:safety#" in fake.streams[0]["system"]
    assert "Do not repeat that" in fake.streams[0]["system"]
    # Only an injury question, no session: no model call at all.
    fake = FakeProvider()
    events = asyncio.run(_answer(_coach(fake), "my ankle is swollen"))
    assert events[-1]["message"]["text"] == SAFETY_REPLY and fake.streams == []


def test_off_topic_is_declined_without_a_model_answer() -> None:
    fake = FakeProvider(json_responses={"_RouteOut": {"intent": "off_topic"}})
    events = asyncio.run(_answer(_coach(fake), "What's the weather in Paris?"))
    assert events[-1]["message"]["text"] == OFF_TOPIC_REPLY and fake.streams == []


def test_refusal_and_drills_context() -> None:
    record = load_golden()
    fake = FakeProvider(["partial"], {"_RouteOut": {"intent": "drills"}}, refuse=True)
    events = asyncio.run(_answer(_coach(fake), "What should I practise?", record))
    assert "can't help" in events[-1]["message"]["text"]
    # The drills query carries the session's note rules, so the matching drill is retrieved.
    assert "kb:drills#throw-and-reach-for-a-straight-arm" in fake.streams[0]["system"]


@pytest.mark.parametrize(
    ("tag", "kept"),
    [("[kb:a#x]", True), ("[kb:a]", True), ("[kb:b#y]", False), ("[kb:a#z]", False)],
)
def test_kb_tags_are_checked_against_retrieved_chunks(tag: str, kept: bool) -> None:
    text, sources = validate_sources(f"Do this {tag}.", [Chunk("kb:a#x", "A: X", "t")])
    assert (tag in text) is kept
    assert bool(sources) is kept


def test_fastest_hit_comes_from_all_hits_and_preserves_precision():
    from shuttlesense.coach.session_docs import measured_stats
    from shuttlesense.schema import Hit

    record = load_golden()
    record.hits = [
        Hit(id=1, frame=30, time_s=1, player="near", stroke="smash", speed_kmh=65.4),
        Hit(id=2, frame=60, time_s=2, player="far", stroke="clear", speed_kmh=91.2),
        Hit(id=3, frame=90, time_s=3, player="near", stroke="smash"),
    ]
    text = measured_stats(record, "compare fastest smashes").text
    assert "near, smash: fastest measured 65.4 km/h (est.), smash [t=1.0s]" in text
    assert "far, smash: no recorded speed estimate" in text
    assert "near: 2 hits; stroke counts: smash 2" in text
    coach = _coach(FakeProvider())
    events = asyncio.run(_answer(coach, "What was my fastest shot?", record))
    assert "Which side" in events[-1]["message"]["text"]
    assert not coach.provider.streams

    from datetime import UTC, datetime

    from shuttlesense.schema import ChatMessage

    history = [
        ChatMessage(role="user", text="What was my fastest shot?", at=datetime.now(UTC)),
        ChatMessage.model_validate(events[-1]["message"]),
    ]

    async def followup():
        return [
            e
            async for e in answer(
                coach, "near", history, ChatSettings(), digest=build_digest(record), record=record
            )
        ]

    assert asyncio.run(followup())[-1]["type"] == "done"
    assert "near, all strokes: fastest measured 65.4" in coach.provider.streams[-1]["system"]


@pytest.mark.skipif(os.getenv("SHUTTLESENSE_TEST_GEMINI") != "1", reason="opt-in Gemini API smoke")
def test_live_gemini_synthetic_session(tmp_path: Path, tiny_video: Path):
    """Exercise production model configuration with disposable synthetic data only."""
    from shuttlesense.coach.router import route

    with _client(tmp_path, coach_provider="gemini") as client:
        provider = client.app.state.coach.provider
        assert provider and provider.name == "gemini", "Set a backend Gemini API key"

        async def model_checks():
            vectors = await provider.embed(["badminton footwork"], "query")
            assert len(vectors) == 1 and len(vectors[0]) > 0
            routed = await route("How should I practise a split step?", provider, job_bound=False)
            assert routed.source == "model"

        client.portal.call(model_checks)
        job = _done_job(client, tiny_video)
        for endpoint, question in (
            (f"/jobs/{job}/chat", "How many hits were recorded in this session?"),
            ("/coach/chat", "What is a split step in badminton?"),
        ):
            response = client.post(endpoint, json={"message": question})
            response.raise_for_status()
            events = _events(response)
            assert events[-1]["type"] == "done" and events[-1]["message"]["text"]
            assert any(e["type"] == "delta" for e in events)
        assert client.get(f"/jobs/{job}/coach/report").json()["generated_by"] == "gemini"
