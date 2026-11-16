from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings


def test_watch_pulls_frames_and_saves_partial(
    tmp_path: Path, tiny_video: Path, monkeypatch
) -> None:
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    with TestClient(app) as client:
        # Exercise the Watch setup with a tracker without loading pose models.
        original_session = app.state.live._session
        trackers = []
        started_times = []

        def session_with_tracker(*args, **kwargs):
            session = original_session(*args, **kwargs)
            started_times.append(session.started_at)
            tracker = SimpleNamespace(watch_outside_tracking=False)
            session.perception.tracker = tracker
            trackers.append(tracker)
            return session

        monkeypatch.setattr(app.state.live, "_session", session_with_tracker)
        # Watch sessions must keep full resolution even when live's latency budget is exceeded.
        app.state.jobs.config["live"]["budget_ms"] = 0
        app.state.jobs.config["live"]["check_every"] = 1
        assert client.get("/health").json()["watch_video"] is True
        with tiny_video.open("rb") as file:
            video = client.post("/videos", files={"file": ("tiny.mp4", file, "video/mp4")}).json()
        with client.websocket_connect("/watch") as ws:
            ws.send_json({"type": "start", "video_id": video["id"], "court": "doubles"})
            started = ws.receive_json()
            assert started["type"] == "started"
            assert trackers[0].watch_outside_tracking is True
            for index in range(3):
                ws.send_json({"type": "next"})
                frame = ws.receive_json()
                assert frame["index"] == index
                assert frame["jpeg"]
                assert any(e["type"] == "frame" and e["frame"] == index for e in frame["events"])
                assert next(e for e in frame["events"] if e["type"] == "stats")["level"] == 0
            ws.send_json({"type": "stop"})
            saved = ws.receive_json()
            assert saved["type"] == "saved" and saved["job_id"] == started["job_id"]
        job = client.get("/jobs/" + saved["job_id"]).json()
        assert job["court"] == "doubles"
        assert datetime.fromisoformat(job["started_at"]).timestamp() == pytest.approx(
            started_times[0], abs=0.001
        )
        assert "partial" in client.get("/videos/" + job["video_id"]).json()["filename"]
        record = client.get("/jobs/" + saved["job_id"] + "/record").json()
        assert record["num_frames"] == 3


def test_watch_finishes_in_order_and_requires_token(tmp_path: Path, tiny_video: Path) -> None:
    app = create_app(
        Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True, token="secret")
    )
    with TestClient(app) as client:
        with client.websocket_connect("/watch") as ws:
            assert ws.receive_json()["code"] == "unauthorized"
            with pytest.raises(WebSocketDisconnect):
                ws.receive_json()
        with tiny_video.open("rb") as file:
            response = client.post(
                "/videos",
                headers={"Authorization": "Bearer secret"},
                files={"file": ("tiny.mp4", file, "video/mp4")},
            )
        source_path = f"/videos/{response.json()['id']}/source"
        assert client.get(source_path).status_code == 401
        assert client.get(source_path + "?token=secret").status_code == 200
        with client.websocket_connect("/watch?token=secret") as ws:
            ws.send_json({"type": "start", "video_id": response.json()["id"]})
            started = ws.receive_json()
            for index in range(started["frames"]):
                ws.send_json({"type": "next"})
                assert ws.receive_json()["index"] == index
            ws.send_json({"type": "next"})
            saved = ws.receive_json()
            assert saved["type"] == "saved"
        job = client.get(
            "/jobs/" + saved["job_id"], headers={"Authorization": "Bearer secret"}
        ).json()
        meta = client.get(
            "/videos/" + job["video_id"], headers={"Authorization": "Bearer secret"}
        ).json()
        assert meta["filename"] == "Watch & Analyze.mp4"


def test_realtime_watch_skips_analysis_but_preserves_timeline(
    tmp_path: Path, tiny_video: Path
) -> None:
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    with TestClient(app) as client:
        with tiny_video.open("rb") as file:
            video = client.post("/videos", files={"file": ("tiny.mp4", file, "video/mp4")}).json()
        source = client.get(f"/videos/{video['id']}/source", headers={"Range": "bytes=0-9"})
        assert source.status_code == 206 and len(source.content) == 10
        with client.websocket_connect("/watch") as ws:
            ws.send_json({"type": "start", "video_id": video["id"], "playback": "realtime"})
            started = ws.receive_json()
            assert started["playback"] == "realtime"
            ws.send_json({"type": "next", "index": 0})
            first = ws.receive_json()
            assert first["index"] == 0 and "jpeg" not in first
            ws.send_json({"type": "next", "index": 4})
            assert ws.receive_json()["index"] == 4
            ws.send_json({"type": "next", "index": 2})
            assert ws.receive_json()["code"] == "bad_request"
            ws.send_json({"type": "stop"})
            saved = ws.receive_json()
        record = client.get(f"/jobs/{saved['job_id']}/record").json()
        assert record["num_frames"] == 5
        assert all(not record["frames"][i]["shuttle"]["visible"] for i in range(1, 4))


def test_saved_watch_render_reports_progress_and_checks_cancellation(tmp_path, monkeypatch):
    from types import SimpleNamespace
    from unittest.mock import Mock

    import shuttlesense.io
    import shuttlesense.render
    from shuttlesense.api.live import LiveManager

    jobs = Mock()
    jobs.config = {}
    storage = Mock()
    storage.job_dir.return_value = tmp_path
    storage.video_deleted.return_value = False
    manager = LiveManager(SimpleNamespace(jobs=jobs, storage=storage), fake=True, ttl_s=0)
    monkeypatch.setattr(shuttlesense.io, "FrameReader", lambda *a, **kw: [])

    def render(*args, progress, **kwargs):
        progress(0.25)
        progress(0.75)
        progress(1.0)

    monkeypatch.setattr(shuttlesense.render, "render_video", render)
    manager._render(
        SimpleNamespace(id="job", video_id="v", overlays=[]),
        SimpleNamespace(height=720, fps=30),
        tmp_path / "source.mp4",
    )
    values = [call.kwargs["progress"] for call in jobs._update.call_args_list]
    assert values[0] == pytest.approx(0.92475)
    assert values[-1] == pytest.approx(0.999)
    assert all(a <= b for a, b in zip(values, values[1:], strict=False))
    assert jobs.check_cancelled.call_count == 4
    jobs.finish_outside.assert_called_once_with("job")
