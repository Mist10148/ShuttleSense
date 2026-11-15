import threading
import time
from pathlib import Path
from types import SimpleNamespace

from fastapi.testclient import TestClient

from shuttlesense.api import watch_background
from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings


def test_background_stop_finishes_watched_frames(tmp_path: Path, tiny_video: Path, monkeypatch):
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    with TestClient(app) as client:
        # Exercise the Watch setup with a tracker without loading pose models.
        original_session = app.state.live._session
        trackers = []

        def session_with_tracker(*args, **kwargs):
            session = original_session(*args, **kwargs)
            tracker = SimpleNamespace(watch_outside_tracking=False)
            session.perception.tracker = tracker
            session.perception.watch_candidates = SimpleNamespace(
                mode="shadow", stats={"frames": 3, "excluded": 5, "tracked_excluded": 0}
            )
            trackers.append(tracker)
            return session

        monkeypatch.setattr(app.state.live, "_session", session_with_tracker)
        with tiny_video.open("rb") as f:
            vid = client.post("/videos", files={"file": ("tiny.mp4", f, "video/mp4")}).json()["id"]
        start = client.post("/watch/background", json={"video_id": vid, "court": "doubles"})
        assert start.status_code == 201, start.text
        assert trackers[0].watch_outside_tracking is True
        job_id = start.json()["job_id"]
        initial_job = client.get("/jobs/" + job_id).json()
        assert initial_job["status"] == "running"
        analysis_started = initial_job["started_at"]
        assert client.delete("/videos/" + vid).status_code == 409
        pos = client.post("/watch/background/" + job_id + "/position", json={"seconds": 0.24})
        assert pos.json()["watched_s"] == 0.24
        stopped = client.post("/watch/background/" + job_id + "/stop", json={"seconds": 0.24})
        assert stopped.json()["target_s"] == 0.24
        for _ in range(200):
            job = client.get("/jobs/" + job_id).json()
            if job["status"] in ("done", "failed"):
                break
            time.sleep(0.05)
        assert job["status"] == "done", job
        assert job["started_at"] == analysis_started
        diagnostic = client.get(f"/watch/background/{job_id}").json()["candidate_diagnostics"]
        assert diagnostic["mode"] == "shadow" and diagnostic["excluded"] == 5
        assert job["court"] == "doubles"
        record = client.get("/jobs/" + job_id + "/record").json()
        assert record["num_frames"] == 6


def test_stop_is_acknowledged_while_worker_is_behind(tmp_path: Path, tiny_video: Path, monkeypatch):
    entered, release = threading.Event(), threading.Event()
    real_frames = watch_background._frames

    def slow_frames(*args):
        entered.set()
        assert release.wait(10)
        return real_frames(*args)

    monkeypatch.setattr(watch_background, "_frames", slow_frames)
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    try:
        with TestClient(app) as client:
            with tiny_video.open("rb") as f:
                vid = client.post("/videos", files={"file": ("tiny.mp4", f, "video/mp4")}).json()[
                    "id"
                ]
            job_id = client.post("/watch/background", json={"video_id": vid}).json()["job_id"]
            client.post(f"/watch/background/{job_id}/position", json={"seconds": 0.24})
            assert entered.wait(5)
            response = client.post(f"/watch/background/{job_id}/stop", json={"seconds": 0.24})
            assert response.json()["target_s"] == 0.24
            assert client.get(f"/jobs/{job_id}").json()["status"] == "running"
            release.set()
            for _ in range(200):
                job = client.get(f"/jobs/{job_id}").json()
                if job["status"] in ("done", "failed"):
                    break
                time.sleep(0.05)
            assert job["status"] == "done", job
            assert client.get(f"/jobs/{job_id}/record").json()["num_frames"] == 6
    finally:
        release.set()


def test_paused_preview_processes_only_acknowledged_frames(tmp_path: Path, tiny_video: Path):
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    with TestClient(app) as client:
        with tiny_video.open("rb") as f:
            vid = client.post("/videos", files={"file": ("tiny.mp4", f, "video/mp4")}).json()["id"]
        job_id = client.post("/watch/background", json={"video_id": vid}).json()["job_id"]
        client.post(f"/watch/background/{job_id}/position", json={"seconds": 0.2})
        for _ in range(100):
            snapshot = client.get(f"/watch/background/{job_id}").json()
            if snapshot["analyzed_s"] >= 0.2:
                break
            time.sleep(0.05)
        assert snapshot["analyzed_s"] == 0.2
        worker = app.state.watch_background[job_id]
        assert worker.entry.session.stats.processed == 5
        assert worker.entry.session.stats.skipped == 0
        time.sleep(0.2)
        assert client.get(f"/watch/background/{job_id}").json()["analyzed_s"] == 0.2
        client.post(f"/watch/background/{job_id}/stop", json={"seconds": 0.2})
        for _ in range(100):
            if client.get(f"/jobs/{job_id}").json()["status"] in ("done", "failed"):
                break
            time.sleep(0.05)
