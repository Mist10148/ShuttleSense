"""Personality over HTTP: the chat routes take it, pass it on, and record who answered."""

from __future__ import annotations

import json
import time
from pathlib import Path

from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings
from shuttlesense.coach.llm import FakeProvider


def _client(tmp_path: Path, provider) -> TestClient:
    settings = Settings(storage_dir=tmp_path / "s", device="cpu", fake_pipeline=True)
    return TestClient(create_app(settings, coach_provider=provider))


def _done_job(client: TestClient, video: Path) -> str:
    with video.open("rb") as f:
        vid = client.post("/videos", files={"file": ("clip.mp4", f, "video/mp4")}).json()["id"]
    job_id = client.post(
        "/jobs",
        json={"video_id": vid, "court_corners_px": [[10, 80], [150, 80], [120, 20], [40, 20]]},
    ).json()["id"]
    for _ in range(1200):
        if client.get(f"/jobs/{job_id}").json()["status"] == "done":
            return job_id
        time.sleep(0.05)
    raise AssertionError("job did not finish")


def _done(res) -> dict:
    lines = [json.loads(x[6:]) for x in res.text.splitlines() if x.startswith("data: ")]
    return lines[-1]


def test_job_chat_uses_the_personality_and_saves_its_label(tmp_path, tiny_video):
    fake = FakeProvider(["Contact in front."], {"_RouteOut": {"intent": "session"}})
    with _client(tmp_path, fake) as client:
        job_id = _done_job(client, tiny_video)
        res = client.post(
            f"/jobs/{job_id}/chat",
            json={
                "message": "Why does my smash hit the net?",
                "personality": {"preset": "witty", "label": "Match prep"},
            },
        )
        assert res.status_code == 200
        assert _done(res)["message"]["personality_label"] == "Match prep"
        assert "## Your communication style: Witty" in fake.streams[0]["system"]
        saved = client.get(f"/jobs/{job_id}/record").json()["chat"]["messages"]
        assert saved[1]["personality_label"] == "Match prep"
        assert "personality_label" not in saved[0]

        # Without a personality nothing is labelled and the prompt has no style block.
        res = client.post(f"/jobs/{job_id}/chat", json={"message": "And my clears?"})
        assert "personality_label" not in _done(res)["message"]
        assert "Your communication style" not in fake.streams[1]["system"]


def test_job_chat_rejects_oversized_personality_text(tmp_path, tiny_video):
    fake = FakeProvider(["ok"], {"_RouteOut": {"intent": "session"}})
    with _client(tmp_path, fake) as client:
        job_id = _done_job(client, tiny_video)
        res = client.post(
            f"/jobs/{job_id}/chat",
            json={"message": "hi", "personality": {"instructions": "x" * 1001}},
        )
        assert res.status_code == 422


def test_general_chat_uses_the_personality(tmp_path):
    fake = FakeProvider(["Split step as they hit."], {"_RouteOut": {"intent": "knowledge"}})
    with _client(tmp_path, fake) as client:
        res = client.post(
            "/coach/chat",
            json={
                "message": "When should I split step?",
                "history": [{"role": "user", "text": "hi"}, {"role": "assistant", "text": "yo"}],
                "personality": {
                    "preset": "mentor",
                    "identity": {"coachName": "Kai"},
                    "instructions": "Call me champ.",
                },
            },
        )
        assert res.status_code == 200
        assert _done(res)["message"]["personality_label"] == "Mentor"
        system = fake.streams[0]["system"]
        assert "## Your communication style: Mentor" in system
        assert 'Your name in this app is "Kai".' in system
        assert "Call me champ." in system


def test_health_says_personalities_are_supported(tmp_path):
    with _client(tmp_path, FakeProvider()) as client:
        assert client.get("/health").json()["coach_personality"] is True


def test_generator_route_returns_a_draft_and_is_rate_limited(tmp_path):
    from tests.test_personality_generator import DRAFT

    fake = FakeProvider(json_responses={"GeneratedPersonality": DRAFT})
    with _client(tmp_path, fake) as client:
        res = client.post(
            "/coach/personality/generate", json={"description": "calm and strict about footwork"}
        )
        assert res.status_code == 200
        assert res.json()["basePreset"] == "stoic"
        for _ in range(4):
            client.post("/coach/personality/generate", json={"description": "calm"})
        res = client.post("/coach/personality/generate", json={"description": "calm"})
        assert res.status_code == 429
        assert (
            client.post("/coach/personality/generate", json={"description": " "}).status_code == 422
        )


def test_generator_route_reports_a_failed_draft(tmp_path):
    fake = FakeProvider(json_responses={"GeneratedPersonality": {"name": "x"}})
    with _client(tmp_path, fake) as client:
        res = client.post("/coach/personality/generate", json={"description": "calm"})
        assert res.status_code == 502
