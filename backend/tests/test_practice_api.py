from threading import Lock
from types import SimpleNamespace

import numpy as np
import pytest
from fastapi import HTTPException

from shuttlesense.api import practice
from shuttlesense.schema import Player


def test_player_candidates_without_court(monkeypatch):
    info = SimpleNamespace(num_frames=10, width=160, height=90)
    jobs = SimpleNamespace(gpu=Lock(), config={"stages": {}}, device="cpu")
    request = SimpleNamespace(
        app=SimpleNamespace(
            state=SimpleNamespace(settings=SimpleNamespace(fake_pipeline=False), jobs=jobs)
        )
    )
    storage = SimpleNamespace(video_source=lambda video_id: "clip.mp4")
    monkeypatch.setattr(practice, "_video_or_404", lambda storage, video_id: info)
    monkeypatch.setattr(practice, "read_frame", lambda source, frame: np.zeros((90, 160, 3)))
    player = Player(bbox=(1, 2, 10, 20), score=0.9)
    monkeypatch.setattr(practice, "load_detector", lambda *args: lambda frame: [player])
    result = practice.practice_candidates("a" * 12, request, storage, 0)
    assert result.candidates[0].bbox == (1, 2, 10, 20)
    assert jobs.gpu.acquire(blocking=False)
    jobs.gpu.release()
    with pytest.raises(HTTPException) as invalid:
        practice.practice_candidates("a" * 12, request, storage, 100)
    assert invalid.value.status_code == 404


def test_candidate_detection_refuses_demo_mode():
    request = SimpleNamespace(
        app=SimpleNamespace(state=SimpleNamespace(settings=SimpleNamespace(fake_pipeline=True)))
    )
    with pytest.raises(HTTPException) as unavailable:
        practice.practice_candidates("a" * 12, request, None, 0)
    assert unavailable.value.status_code == 503


def test_practice_session_continues_after_tracking_loss(tmp_path, tiny_video, monkeypatch):
    import time

    from fastapi.testclient import TestClient

    from shuttlesense.api.main import create_app
    from shuttlesense.api.settings import Settings
    from shuttlesense.schema import Player

    calls = 0
    keypoints = [(3.0, 3.0, 0.0)] * 17
    keypoints[0] = (8, 5, 0.9)
    keypoints[6] = (8, 16, 0.9)
    keypoints[8] = (10, 12, 0.9)
    keypoints[10] = (12, 5, 0.9)
    person = Player(bbox=(2, 2, 40, 60), keypoints=keypoints, score=0.9)

    def detect(frame):
        nonlocal calls
        calls += 1
        return [] if calls == 2 else [person]

    monkeypatch.setattr("shuttlesense.practice.runner.load_detector", lambda *args: detect)
    monkeypatch.setattr("shuttlesense.practice.runner.build_shuttle_tracker", lambda *args: None)
    settings = Settings(storage_dir=tmp_path / "storage", device="cpu", coach_provider="off")
    with TestClient(create_app(settings)) as client:
        with tiny_video.open("rb") as f:
            uploaded = client.post("/videos", files={"file": ("tiny.mp4", f, "video/mp4")})
        assert uploaded.status_code == 201
        video_id = uploaded.json()["id"]
        created = client.post(
            "/practice/sessions",
            json={
                "video_id": video_id,
                "stroke": "clear",
                "arm": "right",
                "attempt_seconds": [0.04],
                "selection_frame": 0,
                "selected_bbox": [2, 2, 40, 60],
            },
        )
        assert created.status_code == 202, created.text
        job_id = created.json()["id"]

        def wait(statuses):
            for _ in range(200):
                job = client.get(f"/practice/sessions/{job_id}").json()
                if job["status"] in statuses:
                    return job
                time.sleep(0.05)
            raise AssertionError("job timed out")

        finished = wait({"done", "failed", "needs_selection"})
        assert finished["status"] == "done", finished
        result = client.get(f"/practice/sessions/{job_id}/result")
        assert result.status_code == 200, result.text
        assert result.json()["report"]["generated_by"] == "rules"
        assert result.json()["observations"][0]["moment_s"] == 0.04
        statuses = [o["status"] for o in result.json()["observations"][0]["observations"]]
        assert statuses == ["unavailable", "unavailable"]
        assert result.json()["unobserved_frames"] == 1
        assert client.get(f"/jobs/{job_id}/video").status_code == 200
        events = result.json()["events"]
        updated = client.put(f"/practice/sessions/{job_id}/events", json={"events": events})
        assert updated.status_code == 200, updated.text
        assert client.get(f"/practice/sessions/{job_id}/result").status_code == 200
        forged = [{"id": "auto-fake", "time_s": 0.08, "source": "automatic", "confirmed": True}]
        assert (
            client.put(f"/practice/sessions/{job_id}/events", json={"events": forged}).status_code
            == 422
        )


def test_process_key_takes_precedence_over_dotenv(tmp_path, monkeypatch):
    from shuttlesense.api import settings as module

    monkeypatch.setattr(module, "BACKEND_DIR", tmp_path)
    monkeypatch.delenv("SHUTTLESENSE_GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    env_file = tmp_path / ".env"
    env_file.write_text("SHUTTLESENSE_GEMINI_API_KEY=local-value\n", encoding="utf-8")
    settings = module.Settings(_env_file=env_file)
    assert settings.gemini_key == "local-value"
    monkeypatch.setenv("GEMINI_API_KEY", "process-value")
    assert module.Settings(_env_file=env_file).gemini_key == "process-value"


def test_completed_auto_event_produces_coach_evidence_without_manual_marks(
    tmp_path, tiny_video, monkeypatch
):
    import time

    from fastapi.testclient import TestClient

    from shuttlesense.api.main import create_app
    from shuttlesense.api.settings import Settings

    points = [(0.0, 0.0, 0.0)] * 17
    for i, point in {0: (5, 4, 0.9), 6: (5, 8, 0.9), 8: (6, 6, 0.9), 10: (7, 3, 0.9)}.items():
        points[i] = point
    player = Player(bbox=(2, 2, 40, 60), keypoints=points, score=0.9)
    monkeypatch.setattr(
        "shuttlesense.practice.runner.load_detector", lambda *args: lambda frame: [player]
    )
    monkeypatch.setattr("shuttlesense.practice.runner.build_shuttle_tracker", lambda *args: None)
    monkeypatch.setattr(
        "shuttlesense.practice.auto.analyze_strokes",
        lambda *args: [
            {
                "frame": 2,
                "time_s": 0.08,
                "stroke": "clear",
                "confidence": 0.8,
                "source": "automatic",
                "confirmed": False,
                "model": "cnn",
            }
        ],
    )
    with TestClient(
        create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", coach_provider="off"))
    ) as client:
        with tiny_video.open("rb") as f:
            video_id = client.post("/videos", files={"file": ("clip.mp4", f, "video/mp4")}).json()[
                "id"
            ]
        response = client.post(
            "/practice/sessions",
            json={
                "video_id": video_id,
                "stroke": "clear",
                "arm": "right",
                "selected_bbox": [2, 2, 40, 60],
            },
        )
        assert response.status_code == 202, response.text
        job_id = response.json()["id"]
        for _ in range(200):
            job = client.get(f"/practice/sessions/{job_id}").json()
            if job["status"] in ("done", "failed", "needs_selection"):
                break
            time.sleep(0.05)
        assert job["status"] == "done", job
        data = client.get(f"/practice/sessions/{job_id}/result").json()
        assert data["events"][0]["confirmed"] is False
        assert data["report"]["evidence"][0]["provenance"] == "automatic"
        assert data["report"]["evidence"][0]["moment_s"] == 0.08
        assert data["report"]["generated_by"] == "rules"
        saved = client.put(f"/practice/sessions/{job_id}/events", json={"events": data["events"]})
        assert saved.status_code == 200
        refreshed = client.get(f"/practice/sessions/{job_id}/result").json()
        assert refreshed["report"]["evidence"][0]["provenance"] == "automatic"


def test_practice_pause_resume_and_stop_saves_processed_video(tmp_path, tiny_video, monkeypatch):
    import threading
    import time

    import cv2
    from fastapi.testclient import TestClient

    from shuttlesense.api.main import create_app
    from shuttlesense.api.settings import Settings

    entered = threading.Event()
    release = threading.Event()
    calls = []
    person = Player(bbox=(2, 2, 40, 60), score=0.9)

    def detect(frame):
        calls.append(1)
        if len(calls) == 1:
            entered.set()
            assert release.wait(5)
        return [person]

    monkeypatch.setattr("shuttlesense.practice.runner.load_detector", lambda *args: detect)
    monkeypatch.setattr("shuttlesense.practice.runner.build_shuttle_tracker", lambda *args: None)
    with TestClient(
        create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", coach_provider="off"))
    ) as client:
        with tiny_video.open("rb") as f:
            video_id = client.post("/videos", files={"file": ("clip.mp4", f, "video/mp4")}).json()[
                "id"
            ]
        job_id = client.post(
            "/practice/sessions",
            json={
                "video_id": video_id,
                "stroke": "clear",
                "arm": "right",
                "selected_bbox": [2, 2, 40, 60],
            },
        ).json()["id"]
        assert entered.wait(5)
        assert client.post(f"/practice/sessions/{job_id}/control/pause").status_code == 200
        release.set()
        time.sleep(0.3)
        assert len(calls) == 1
        assert client.get(f"/practice/sessions/{job_id}").json()["control"]["paused"] is True
        assert client.post(f"/practice/sessions/{job_id}/control/resume").status_code == 200
        assert client.post(f"/practice/sessions/{job_id}/control/stop").status_code == 200
        for _ in range(200):
            job = client.get(f"/practice/sessions/{job_id}").json()
            if job["status"] in ("done", "failed"):
                break
            time.sleep(0.05)
        assert job["status"] == "done", job
        result = client.get(f"/practice/sessions/{job_id}/result").json()
        assert result["stopped_early"] is True
        assert 1 <= result["processed_frames"] < 10
        cap = cv2.VideoCapture(str(tmp_path / "storage" / "jobs" / job_id / "annotated.mp4"))
        assert int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) == result["processed_frames"]
        cap.release()


def test_analysis_is_immediate_and_edited_events_invalidate_stale_notes(tmp_path):
    import json

    from fastapi.testclient import TestClient

    from shuttlesense.api.main import create_app
    from shuttlesense.api.models import Job
    from shuttlesense.api.settings import Settings
    from shuttlesense.coach.llm import ChatError
    from shuttlesense.practice.evidence import assess_attempt
    from shuttlesense.practice.report import ReportChoice
    from shuttlesense.schema import ClipRecord, Frame, Players

    class Provider:
        name = "gemini"
        calls = 0
        stream_calls = 0
        on_stream = None
        error = None

        async def generate_json(self, system, prompt, schema):
            self.calls += 1
            return ReportChoice(evidence_ids=["attempt-1-observation-1"])

        async def stream(self, system, messages):
            self.stream_calls += 1
            assert '"stroke": "clear"' in system or '"stroke": "smash"' in system
            assert messages[-1] == {"role": "user", "text": "Why review this clear?"}
            if self.error:
                raise self.error
            yield "Review the reach [t=0.1s] [t=42s] [kb:made_up#nothing]."
            if self.on_stream:
                self.on_stream()

    points = [(0.0, 0.0, 0.0)] * 17
    for i, point in {0: (5, 4, 0.9), 6: (5, 8, 0.9), 8: (6, 6, 0.9), 10: (7, 3, 0.9)}.items():
        points[i] = point
    player = Player(bbox=(0, 0, 10, 20), keypoints=points, score=0.9)
    event = {
        "id": "auto-0",
        "frame": 1,
        "time_s": 0.1,
        "stroke": "clear",
        "confidence": 0.8,
        "source": "automatic",
        "confirmed": False,
        "model": "cnn",
    }
    data = {
        "setup": {"arm": "right"},
        "fps": 10,
        "processed_frames": 2,
        "observations": [
            assess_attempt(player, "clear", "right", 0.1, provenance="automatic").model_dump()
        ],
        "events": [event],
        "automatic_events": [event],
        "analysis_notes": [
            {
                "event_id": "auto-0",
                "time_s": 0.1,
                "stroke": "clear",
                "rule": "elbow_extension",
                "passed": False,
                "tip": "Review reach",
                "value": 1,
            }
        ],
    }
    record = ClipRecord(
        clip_id="x",
        mode="practice",
        fps=10,
        width=100,
        height=80,
        num_frames=2,
        frames=[Frame(frame=i, players=Players(near=player)) for i in range(2)],
    )
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", coach_provider="off"))
    with TestClient(app) as client:
        job_id = "a" * 12
        app.state.jobs.add(Job(id=job_id, video_id="b" * 12, mode="practice", status="done"))
        folder = app.state.storage.job_dir(job_id)
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "practice.json").write_text(json.dumps(data), encoding="utf8")
        assert client.get(f"/practice/sessions/{job_id}/report").status_code == 409
        (folder / "annotated.mp4").write_bytes(b"rendered")
        (folder / "practice_frames.json").write_text(record.model_dump_json(), encoding="utf8")
        provider = Provider()
        app.state.coach_provider = provider
        analysis = client.get(f"/practice/sessions/{job_id}/analysis")
        assert analysis.status_code == 200
        assert analysis.json()["rules_report"]["generated_by"] == "rules"
        assert analysis.json()["rules_report"]["evidence"]
        assert provider.calls == 0
        report = client.get(f"/practice/sessions/{job_id}/report").json()
        assert report["generated_by"] == "gemini"
        chat_path = f"/practice/sessions/{job_id}/chat"
        question = {
            "message": "Why review this clear?",
            "context_version": report["context_version"],
        }

        def ask(body):
            response = client.post(chat_path, json=body)
            assert response.status_code == 200
            return [
                json.loads(line[6:])
                for line in response.text.splitlines()
                if line.startswith("data: ")
            ]

        assert (
            client.post(chat_path, json={**question, "context_version": "0" * 64}).status_code
            == 409
        )
        assert client.post(f"/practice/sessions/{'b' * 12}/chat", json=question).status_code == 404
        assert provider.stream_calls == 0
        done = ask(question)[-1]
        assert done["type"] == "done"
        assert [moment["frame"] for moment in done["message"]["citations"]] == [1]
        assert "[t=42s]" not in done["message"]["text"]
        assert "[kb:made_up#nothing]" not in done["message"]["text"]
        assert done["sources"] == []
        provider.error = ChatError("Quota exhausted", 429)
        assert ask(question)[-1] == {"type": "error", "status": 429, "detail": "Quota exhausted"}
        provider.error = None
        assert client.get(f"/practice/sessions/{job_id}/report").status_code == 200
        assert provider.calls == 1
        assert client.post(f"/practice/sessions/{job_id}/report").status_code == 200
        assert provider.calls == 2
        corrected = {**event, "stroke": "smash", "confirmed": True}
        updated = client.put(f"/practice/sessions/{job_id}/events", json={"events": [corrected]})
        assert updated.status_code == 200 and updated.json()["analysis_notes"] == []
        assert client.post(chat_path, json=question).status_code == 409
        report = client.get(f"/practice/sessions/{job_id}/report").json()
        assert all(item["stroke"] == "smash" for item in report["evidence"])
        assert provider.calls == 3
        provider.on_stream = (folder / "practice_report.json").unlink
        events = ask({**question, "context_version": report["context_version"]})
        assert [event["type"] for event in events] == ["delta", "error"]
        assert events[-1]["status"] == 409
        provider.on_stream = None
        updated = client.put(f"/practice/sessions/{job_id}/events", json={"events": []})
        assert updated.status_code == 200 and updated.json()["analysis_notes"] == []
        report = client.get(f"/practice/sessions/{job_id}/report").json()
        assert report["evidence"] == [] and provider.calls == 3
        assert (
            client.post(
                chat_path, json={**question, "context_version": report["context_version"]}
            ).status_code
            == 409
        )
        data["unobserved_indices"] = [1]
        (folder / "practice.json").write_text(json.dumps(data), encoding="utf8")
        report = client.get(f"/practice/sessions/{job_id}/report").json()
        assert report["evidence"] == [] and provider.calls == 3


def test_old_notes_do_not_reappear_after_prior_event_edits():
    event = {"id": "auto-1", "source": "automatic", "stroke": "smash", "time_s": 1.0, "frame": 10}
    data = {
        "fps": 10,
        "automatic_events": [event],
        "events": [],
        "analysis_notes": [{"time_s": 1.0, "stroke": "smash", "rule": "test"}],
    }
    assert practice._current_analysis_notes(data) == []
    data["events"] = [event]
    assert len(practice._current_analysis_notes(data)) == 1
    data["automatic_events"].append({**event, "id": "auto-2"})
    assert practice._current_analysis_notes(data) == []
