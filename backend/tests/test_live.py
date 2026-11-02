"""WS /live end to end with the fake live source (no GPU, weights or camera)."""

from __future__ import annotations

import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings
from shuttlesense.stream.fake_source import blank_frames, encode

START = {"type": "start", "fps": 30, "width": 640, "height": 360, "name": "Court 2"}


def make_client(tmp_path: Path, **settings) -> TestClient:
    settings.setdefault("fake_pipeline", True)
    return TestClient(
        create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", **settings))
    )


def _send_frames(ws, count: int, first: int = 0) -> list[dict]:
    """Send frames one at a time and collect every event they produce."""
    events = []
    for i, frame in enumerate(blank_frames(count), start=first):
        ws.send_bytes(encode(frame, i, time.time() * 1000))
        while True:
            e = ws.receive_json()
            events.append(e)
            if e["type"] == "frame":
                break
        # Events committed by this frame follow its frame event; drain them on the next one.
    return events


def _wait_done(client: TestClient, job_id: str) -> dict:
    for _ in range(200):
        job = client.get(f"/jobs/{job_id}").json()
        if job["status"] in ("done", "failed"):
            return job
        time.sleep(0.05)
    raise AssertionError("live job never finished rendering")


def test_live_session_streams_events_and_saves_a_job(tmp_path: Path) -> None:
    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            started = ws.receive_json()
            assert started["type"] == "started" and not started["resumed"]
            assert (started["width"], started["height"]) == (640, 360)
            events = _send_frames(ws, 240)
            ws.send_json({"type": "stop"})
            tail = []
            while (e := ws.receive_json())["type"] != "saved":
                tail.append(e)
            saved = e
        kinds = {e["type"] for e in events + tail}
        assert {"frame", "hit", "rally", "line_call", "score", "stats"} <= kinds
        frame = next(e for e in events if e["type"] == "frame" and e["shuttle"]["visible"])
        assert frame["court"]["shuttle"] is not None and "latency_ms" in frame
        hit = next(e for e in events if e["type"] == "hit")["hit"]
        assert hit["stroke"] == "serve"  # fake mode labels strokes from the synthetic plan
        call = next(e for e in events if e["type"] == "line_call")["line_call"]
        assert call["call"] == "in" and not call["uncertain"]

        job = _wait_done(client, saved["job_id"])
        assert job["status"] == "done" and job["mode"] == "live" and job["outputs"]["video"]
        record = client.get(f"/jobs/{job['id']}/record").json()
        assert record["mode"] == "live" and record["num_frames"] == 240
        assert len(record["line_calls"]) >= 2 and record["coaching"] is not None
        assert client.get(f"/videos/{job['video_id']}").json()["filename"] == "Court 2.mp4"
        assert job["id"] in [j["id"] for j in client.get("/jobs").json()]
        # REST overrides work on a saved live session like on an upload.
        res = client.patch(f"/jobs/{job['id']}/line-calls/{call['id']}", json={"call": "out"})
        assert res.status_code == 200


def test_live_override_and_correction_over_the_socket(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json(START)
        ws.receive_json()
        events = _send_frames(ws, 230)
        call = next(e for e in events if e["type"] == "line_call")["line_call"]
        ws.send_json({"type": "override", "line_call_id": call["id"], "call": "out"})
        update = ws.receive_json()
        assert update["type"] == "line_call" and update["line_call"]["override"]["call"] == "out"
        assert ws.receive_json()["type"] == "score"
        ws.send_json({"type": "correct", "rally_index": 0, "winner": "far"})
        score = ws.receive_json()
        assert score["type"] == "score" and score["rallies"][0]["winner"] == "far"
        ws.send_json({"type": "override", "line_call_id": 99, "call": "in"})
        assert ws.receive_json()["code"] == "not_found"


def test_resume_after_a_dropped_connection(tmp_path: Path) -> None:
    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            session_id = ws.receive_json()["session_id"]
            _send_frames(ws, 20)
        # A new session is refused while the dropped one waits for its resume.
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            assert ws.receive_json()["code"] == "busy"
        with client.websocket_connect("/live") as ws:
            ws.send_json({"type": "resume", "session_id": session_id})
            started = ws.receive_json()
            assert started["resumed"] and started["frames"] == 20
            events = _send_frames(ws, 5, first=20)
            assert [e["frame"] for e in events if e["type"] == "frame"] == list(range(20, 25))
            ws.send_json({"type": "stop"})
            while (e := ws.receive_json())["type"] != "saved":
                pass
            assert e["job_id"]
        with client.websocket_connect("/live") as ws:
            ws.send_json({"type": "resume", "session_id": session_id})
            assert ws.receive_json()["code"] == "not_found"


def test_dropped_session_is_saved_after_the_ttl(tmp_path: Path) -> None:
    with make_client(tmp_path, live_session_ttl_s=0.2) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            ws.receive_json()
            _send_frames(ws, 15)
        for _ in range(100):
            jobs = client.get("/jobs").json()
            if jobs:
                break
            time.sleep(0.05)
        assert jobs and jobs[0]["mode"] == "live"
        # The GPU is free again.
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            assert ws.receive_json()["type"] == "started"


def test_stop_without_frames_saves_nothing(tmp_path: Path) -> None:
    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            ws.receive_json()
            ws.send_json({"type": "stop"})
            assert ws.receive_json() == {
                "type": "saved", "job_id": None, "video_id": None,
                "stats": {"received": 0, "processed": 0, "skipped": 0, "dropped": 0,
                          "p50_ms": 0.0, "p95_ms": 0.0},
            }  # fmt: skip
        assert client.get("/jobs").json() == []


@pytest.mark.parametrize(
    ("message", "code"),
    [
        ({"type": "hello"}, "bad_request"),
        ({**START, "fps": 0}, "bad_request"),
        ({**START, "corners": [[0, 0], [1, 1], [0, 1], [1, 0]]}, "bad_request"),
        ({**START, "corners": [[300, 200], [310, 200], [308, 190], [302, 190]]}, "bad_request"),
        ({**START, "start_score": {"near": -1, "far": 0}}, "bad_request"),
        ({**START, "start_score": {"near": 21, "far": 3}}, "bad_request"),
        ({**START, "start_score": {"near": 31, "far": 31}}, "bad_request"),
        ({**START, "best_of": 5}, "bad_request"),
        ({**START, "first_server": "left"}, "bad_request"),
        ({"type": "resume", "session_id": "nope"}, "not_found"),
    ],
)
def test_bad_first_messages(tmp_path: Path, message: dict, code: str) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json(message)
        assert ws.receive_json()["code"] == code
        with pytest.raises(WebSocketDisconnect):
            ws.receive_json()


def test_non_object_first_message_is_a_bad_request(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json([1, 2])
        assert ws.receive_json()["code"] == "bad_request"


def test_quality_level_stops_at_the_last_configured_scale() -> None:
    from shuttlesense.stream.perception import ReplayPerception
    from shuttlesense.stream.session import LiveSession, StartRequest
    from shuttlesense.stream.synthetic import synthetic_record

    record, _ = synthetic_record()
    config = {"live": {"scales": [1.0, 0.5], "check_every": 1, "budget_ms": 0}}
    session = LiveSession(
        session_id="s", request=StartRequest(fps=30, width=640, height=360), config=config,
        perception=ReplayPerception(record, (640, 360)), court_corners=None, recording=None,
    )  # fmt: skip
    for i, frame in enumerate(blank_frames(5)):
        session.process(encode(frame, i, i * 33.0)[12:], i, i * 33.0, time.monotonic())
    assert session.level == 1


def test_token_is_required_when_set(tmp_path: Path) -> None:
    with make_client(tmp_path, token="s3cret") as client:
        with client.websocket_connect("/live") as ws:
            assert ws.receive_json()["code"] == "unauthorized"
        with client.websocket_connect("/live?token=s3cret") as ws:
            ws.send_json(START)
            assert ws.receive_json()["type"] == "started"
            ws.send_json({"type": "stop"})
            assert ws.receive_json()["type"] == "saved"


def test_non_object_control_message_is_rejected_not_fatal(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json(START)
        ws.receive_json()
        ws.send_text("1")
        assert ws.receive_json()["code"] == "bad_message"
        ws.send_json({"type": "stop"})
        assert ws.receive_json()["type"] == "saved"


def test_malformed_json_is_rejected_not_fatal(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json(START)
        ws.receive_json()
        ws.send_text("{bad")
        assert ws.receive_json()["code"] == "bad_message"
        assert [e["frame"] for e in _send_frames(ws, 2) if e["type"] == "frame"] == [0, 1]
        ws.send_json({"type": "stop"})
        while ws.receive_json()["type"] != "saved":
            pass


def test_second_drop_restarts_the_ttl(tmp_path: Path) -> None:
    """Each drop arms one timer: the first drop's timer must not save a resumed session."""
    with make_client(tmp_path, live_session_ttl_s=1.0) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            session_id = ws.receive_json()["session_id"]
            _send_frames(ws, 3)
        dropped = time.monotonic()
        with client.websocket_connect("/live") as ws:
            ws.send_json({"type": "resume", "session_id": session_id})
            assert ws.receive_json()["resumed"]
            time.sleep(0.6)
        # Past the first drop's ttl, inside the second one's.
        time.sleep(max(0.0, 1.2 - (time.monotonic() - dropped)))
        with client.websocket_connect("/live") as ws:
            ws.send_json({"type": "resume", "session_id": session_id})
            assert ws.receive_json()["type"] == "started"
            ws.send_json({"type": "stop"})
            while ws.receive_json()["type"] != "saved":
                pass


def test_a_failing_frame_frees_the_gpu_after_the_ttl(tmp_path: Path, monkeypatch) -> None:
    from shuttlesense.stream.session import LiveSession

    def boom(*_args, **_kwargs):
        raise RuntimeError("perception crashed")

    with make_client(tmp_path, live_session_ttl_s=0.2) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            ws.receive_json()
            _send_frames(ws, 3)
            monkeypatch.setattr(LiveSession, "process", boom)
            ws.send_bytes(encode(next(blank_frames(1)), 3, time.time() * 1000))
            assert ws.receive_json()["code"] == "internal"
        monkeypatch.undo()
        # The session was detached, not leaked: it is saved after the ttl and the GPU freed.
        for _ in range(100):
            if client.get("/jobs").json():
                break
            time.sleep(0.05)
        assert client.app.state.jobs.gpu.acquire(blocking=False)
        client.app.state.jobs.gpu.release()


def test_live_waits_for_a_running_job(tmp_path: Path) -> None:
    with make_client(tmp_path) as client:
        client.app.state.jobs.gpu.acquire()
        try:
            with client.websocket_connect("/live") as ws:
                ws.send_json(START)
                assert ws.receive_json()["code"] == "busy"
        finally:
            client.app.state.jobs.gpu.release()
