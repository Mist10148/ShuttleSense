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
            assert "provider_diagnostics" in started
            assert trackers[0].watch_outside_tracking is True
            for index in range(3):
                ws.send_json({"type": "next"})
                frame = ws.receive_json()
                assert frame["index"] == index
                assert set(frame["timing_ms"]) == {"read", "jpeg", "processing"}
                assert "profile_ms" not in frame
                assert "previous_transport" not in frame
                assert "server_serialize_epoch_us" not in frame
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


def test_watch_profile_is_opt_in_and_frame_correlated(tmp_path, tiny_video):
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    with TestClient(app) as client:
        with tiny_video.open("rb") as source:
            video = client.post("/videos", files={"file": ("tiny.mp4", source)}).json()
        with client.websocket_connect("/watch") as ws:
            ws.send_json({"type": "start", "video_id": video["id"], "profile_diagnostics": True})
            assert ws.receive_json()["type"] == "started"
            for index in range(3):
                ws.send_json({"type": "next"})
                frame = ws.receive_json()
                assert frame["index"] == index
                assert frame["profile_ms"]["normalize_wall"] >= 0
                assert frame["profile_ms"]["jpeg_decode_wall"] >= 0
                assert frame["profile_ms"]["record_wall"] >= 0
                assert isinstance(frame["server_serialize_epoch_us"], int)
                if index == 0:
                    assert "previous_transport" not in frame
                else:
                    transport = frame["previous_transport"]
                    assert transport["frame"] == index - 1
                    assert transport["serialize_ms"] >= 0
                    assert transport["send_await_ms"] >= 0
                    assert transport["utf8_bytes"] > 0
            ws.send_json({"type": "stop"})
            assert ws.receive_json()["type"] == "saved"


@pytest.mark.parametrize("finish", ["stop", "disconnect", "failure"])
def test_complete_watch_parallelizes_and_cleans_up(tmp_path, tiny_video, monkeypatch, finish):
    import time
    from threading import Barrier

    from shuttlesense.schema import Players, Shuttle
    from shuttlesense.stream import perception as perception_module
    from shuttlesense.stream.watch_parallel import ParallelWatchPerception

    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    closed = []
    original_close = ParallelWatchPerception.close

    def close(self):
        closed.append(True)
        original_close(self)

    class Models:
        available = {"tracking": True, "pose": True}
        barrier = Barrier(2, timeout=3)
        calls = 0

        def _shuttle(self, _frame):
            self.barrier.wait()
            return Shuttle()

        def _players(self, _frame):
            self.barrier.wait()
            self.calls += 1
            if finish == "failure" and self.calls == 4:
                raise RuntimeError("pose failed")
            return Players()

    with TestClient(app) as client:
        manager = app.state.live
        create_session = manager._session

        def session(*args, **kwargs):
            manager.fake = True
            try:
                result = create_session(*args, **kwargs)
            finally:
                manager.fake = False
            result.perception = Models()
            return result

        monkeypatch.setattr(manager, "_session", session)
        monkeypatch.setattr(perception_module, "enable_watch_player_continuity", lambda _: None)
        monkeypatch.setattr(ParallelWatchPerception, "close", close)
        manager.fake = False
        app.state.jobs.config.setdefault("watch", {})["frame_parallel_perception"] = True
        with tiny_video.open("rb") as source:
            video = client.post("/videos", files={"file": ("tiny.mp4", source)}).json()
        with client.websocket_connect("/watch") as ws:
            ws.send_json({"type": "start", "video_id": video["id"]})
            started = ws.receive_json()
            assert started["type"] == "started"
            for index in range(3):
                ws.send_json({"type": "next"})
                assert ws.receive_json()["index"] == index
            if finish == "stop":
                ws.send_json({"type": "stop"})
                assert ws.receive_json()["type"] == "saved"
            elif finish == "failure":
                ws.send_json({"type": "next"})
                assert ws.receive_json()["type"] == "error"
        for _ in range(100):
            response = client.get(f"/jobs/{started['job_id']}/record")
            if response.status_code == 200:
                break
            time.sleep(0.01)
        assert closed == [True]
        record = response.json()
        assert [frame["frame"] for frame in record["frames"]] == [0, 1, 2]


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
    monkeypatch.setattr(
        shuttlesense.io, "FrameReader", lambda *a, **kw: SimpleNamespace(frames=lambda *_: [])
    )

    def render(*args, progress, **kwargs):
        progress(0.25)
        progress(0.75)
        progress(1.0)

    monkeypatch.setattr(shuttlesense.render, "render_video", render)
    manager._render(
        SimpleNamespace(id="job", video_id="v", overlays=[]),
        SimpleNamespace(height=720, fps=30, frames=[]),
        tmp_path / "source.mp4",
    )
    values = [call.kwargs["progress"] for call in jobs._update.call_args_list]
    assert values[0] == pytest.approx(0.92475)
    assert values[-1] == pytest.approx(0.999)
    assert all(a <= b for a, b in zip(values, values[1:], strict=False))
    assert jobs.check_cancelled.call_count == 4
    jobs.finish_outside.assert_called_once_with("job")


@pytest.mark.parametrize("parallel", [False, True])
def test_watch_practice_partial_session_uses_selected_player_and_saves_report(
    tmp_path, tiny_video, monkeypatch, parallel
):
    import time
    from threading import Event

    import shuttlesense.render as render_module
    from shuttlesense.schema import Player, Players, Shuttle
    from shuttlesense.stream import perception as perception_module

    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))
    person = Player(bbox=(2, 2, 40, 60), score=0.9)
    render_started, render_release = Event(), Event()
    original_render = render_module.render_video

    def delayed_render(*args, **kwargs):
        render_started.set()
        if not render_release.wait(5):
            raise TimeoutError("test did not release render")
        return original_render(*args, **kwargs)

    monkeypatch.setattr(render_module, "render_video", delayed_render)

    class Models:
        available = {"tracking": False, "pose": True}
        min_person_score = 0.4
        calls = 0

        def _shuttle(self, frame):
            return Shuttle()

        def _players(self, frame):
            self.calls += 1
            return Players(near=None if self.calls in (2, 3) else person)

    with TestClient(app) as client:
        manager = app.state.live
        original = manager._session

        def session(*args, **kwargs):
            manager.fake = True
            try:
                result = original(*args, **kwargs)
            finally:
                manager.fake = False
            result.perception = Models()
            return result

        monkeypatch.setattr(manager, "_session", session)
        monkeypatch.setattr(perception_module, "enable_watch_player_continuity", lambda _: None)
        manager.fake = False
        app.state.jobs.config.setdefault("watch", {})["frame_parallel_perception"] = parallel
        with tiny_video.open("rb") as f:
            video = client.post("/videos", files={"file": ("clip.mp4", f, "video/mp4")}).json()
        with client.websocket_connect("/watch") as ws:
            ws.send_json(
                {
                    "type": "start",
                    "video_id": video["id"],
                    "mode": "practice",
                    "court": "singles",
                    "playback": "complete",
                    "corners": [[20, 80], [140, 80], [110, 10], [50, 10]],
                    "practice_setup": {
                        "video_id": video["id"],
                        "selected_bbox": [2, 2, 40, 60],
                        "stroke": "clear",
                        "arm": "right",
                        "attempt_seconds": [0.04],
                    },
                }
            )
            started = ws.receive_json()
            assert started["type"] == "started", started
            for i in range(4):
                ws.send_json({"type": "next"})
                response = ws.receive_json()
                assert response["index"] == i
                frame = next(event for event in response["events"] if event["type"] == "frame")
                assert bool(frame["display_players"]) == (i in (0, 3))
            ws.send_json({"type": "stop"})
            saved = ws.receive_json()
            assert saved["job_id"] == started["job_id"]
        try:
            assert render_started.wait(5)
            assert client.get(f"/practice/sessions/{saved['job_id']}/result").status_code == 409
        finally:
            render_release.set()
        for _ in range(100):
            job = client.get(f"/jobs/{saved['job_id']}").json()
            if job["status"] in ("done", "failed"):
                break
            time.sleep(0.05)
        assert job["status"] == "done", job
        assert job["mode"] == "practice"
        result = client.get(f"/practice/sessions/{saved['job_id']}/result")
        assert result.status_code == 200, result.text
        assert result.json()["processed_frames"] == 4
        assert result.json()["stopped_early"] is True
        assert result.json()["unobserved_frames"] == 2
        assert result.json()["observations"][0]["observations"][0]["status"] == "unavailable"


def test_practice_warns_when_selected_player_has_no_watch_slot(tmp_path, tiny_video, monkeypatch):
    from shuttlesense.schema import Player, Players, Shuttle
    from shuttlesense.stream import perception as perception_module

    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=True))

    class Models:
        available = {"tracking": False, "pose": True}

        def _shuttle(self, frame):
            return Shuttle()

        def _players(self, frame):
            return Players(near=Player(bbox=(0, 0, 20, 40), score=0.9))

    with TestClient(app) as client:
        manager = app.state.live
        original = manager._session

        def session(*args, **kwargs):
            manager.fake = True
            try:
                result = original(*args, **kwargs)
            finally:
                manager.fake = False
            result.perception = Models()
            return result

        monkeypatch.setattr(manager, "_session", session)
        monkeypatch.setattr(perception_module, "enable_watch_player_continuity", lambda _: None)
        manager.fake = False
        with tiny_video.open("rb") as f:
            video = client.post("/videos", files={"file": ("clip.mp4", f, "video/mp4")}).json()
        with client.websocket_connect("/watch") as ws:
            ws.send_json(
                {
                    "type": "start",
                    "mode": "practice",
                    "court": "singles",
                    "video_id": video["id"],
                    "corners": [[20, 80], [140, 80], [110, 10], [50, 10]],
                    "practice_setup": {
                        "video_id": video["id"],
                        "stroke": "clear",
                        "arm": "right",
                        "selected_bbox": [100, 10, 20, 40],
                    },
                }
            )
            assert ws.receive_json()["type"] == "started"
            for i in range(10):
                ws.send_json({"type": "next"})
                response = ws.receive_json()
                frame = next(event for event in response["events"] if event["type"] == "frame")
                assert frame["selected_visible"] is False
                assert frame["selection_failed"] == (i == 9)
            ws.send_json({"type": "stop"})
            assert ws.receive_json()["type"] == "saved"
