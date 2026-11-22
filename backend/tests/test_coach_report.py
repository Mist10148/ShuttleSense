"""AI coaching report: schema, model output checks, rules fallback and cache."""

from __future__ import annotations

import asyncio
import os
import time
from pathlib import Path

from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings
from shuttlesense.coach.chat import Coach
from shuttlesense.coach.digest import build_digest
from shuttlesense.coach.index import Retriever
from shuttlesense.coach.llm import ChatError, FakeProvider
from shuttlesense.coach.report import (
    REPORT_FILE,
    CoachReport,
    generate_report,
    rules_report,
)
from shuttlesense.coach.session_docs import RULE_DRILLS
from shuttlesense.fake import load_golden


def _model_report(moment: float) -> dict:
    return {
        "summary": "Strong serve, bent arm on overheads.",
        "strengths": ["Fast smash"],
        "weaknesses": [
            {
                "title": "Bent arm",
                "evidence": "elbow_extension failed on the smash",
                "moments": [moment, 42.0],
                "drill": "Throw and reach",
            }
        ],
        "drills": [
            {
                "name": "Throw and reach",
                "purpose": "Straight arm",
                "how": "Throw shuttles overhead",
                "kb_source": "kb:drills#throw-and-reach-for-a-straight-arm",
            },
            {"name": "Made up", "purpose": "x", "how": "y", "kb_source": "kb:nope#nope"},
        ],
        "next_session_goals": ["Straighter arm on smashes"],
    }


def test_every_rule_maps_to_a_drill_chunk() -> None:
    ids = set(Retriever(None, None).by_id)
    assert set(RULE_DRILLS.values()) <= ids


def test_rules_report_from_session_notes() -> None:
    record = load_golden()
    report = rules_report(record, Retriever(None, None).by_id)
    assert report.generated_by == "rules"
    assert len(report.weaknesses) == 3
    first = report.weaknesses[0]
    assert "Bent hitting arm" in first.evidence and first.moments == [0.833]
    assert report.drills[0].kb_source == "kb:drills#throw-and-reach-for-a-straight-arm"
    assert report.next_session_goals
    CoachReport.model_validate(report.model_dump(mode="json"))


def test_model_report_moments_and_sources_are_checked() -> None:
    record = load_golden()
    fake = FakeProvider(json_responses={"_ReportOut": _model_report(1.52)})
    coach = Coach(fake, Retriever(fake, None))
    report = asyncio.run(generate_report(coach, record, build_digest(record)))
    assert report.generated_by == "gemini"  # a fake provider reports as the default
    assert report.weaknesses[0].moments == [1.5]  # snapped to the hit; 42.0 dropped
    assert report.drills[0].kb_source == "kb:drills#throw-and-reach-for-a-straight-arm"
    assert len(report.drills) == 1
    prompt = fake.json_calls[0]["prompt"]
    assert "[kb:drills#throw-and-reach-for-a-straight-arm]" in prompt and "TOP FIX" in prompt


def test_model_failure_falls_back_to_rules() -> None:
    record = load_golden()
    fake = FakeProvider(json_responses={"_ReportOut": ChatError("down", 503)})
    coach = Coach(fake, Retriever(fake, None))
    assert asyncio.run(generate_report(coach, record, build_digest(record))).generated_by == "rules"


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
    for _ in range(1200):  # generous: CI machines can be slow
        if client.get(f"/jobs/{job_id}").json()["status"] == "done":
            return job_id
        time.sleep(0.05)
    raise AssertionError("job did not finish")


def test_report_endpoint_caches_until_the_record_changes(tmp_path: Path, tiny_video: Path) -> None:
    fake = FakeProvider(json_responses={"_ReportOut": lambda _: _model_report(0.0)})
    with _client(tmp_path, fake) as client:
        job_id = _done_job(client, tiny_video)
        first = client.get(f"/jobs/{job_id}/coach/report")
        assert first.status_code == 200
        CoachReport.model_validate(first.json())
        job_dir = tmp_path / "s" / "jobs" / job_id
        assert (job_dir / REPORT_FILE).exists()
        client.get(f"/jobs/{job_id}/coach/report")
        assert len(fake.json_calls) == 1  # cached
        client.post(f"/jobs/{job_id}/coach/report")
        assert len(fake.json_calls) == 2  # regenerated
        record = job_dir / "record.json"
        os.utime(record, (time.time() + 5, time.time() + 5))  # the record changed
        client.get(f"/jobs/{job_id}/coach/report")
        assert len(fake.json_calls) == 3
        assert client.get("/jobs/000000000000/coach/report").status_code == 404


def test_report_without_provider_uses_rules(tmp_path: Path, tiny_video: Path, monkeypatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    with _client(tmp_path, None) as client:
        job_id = _done_job(client, tiny_video)
        res = client.get(f"/jobs/{job_id}/coach/report")
        assert res.status_code == 200 and res.json()["generated_by"] == "rules"
