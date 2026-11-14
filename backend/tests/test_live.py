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
        ws.send_bytes(encode(frame, i, i * 1000 / START["fps"]))
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


@pytest.mark.parametrize("timestamp", [float("nan"), float("inf"), float("-inf")])
def test_invalid_capture_time_does_not_break_session(tmp_path: Path, timestamp: float) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json(START)
        ws.receive_json()
        frame = next(blank_frames(1))
        ws.send_bytes(encode(frame, 0, timestamp))
        assert ws.receive_json()["code"] == "bad_frame"
        ws.send_bytes(encode(frame, 1, time.time() * 1000))
        assert ws.receive_json()["type"] == "frame"


def test_capture_time_must_not_go_backwards_across_resume(tmp_path: Path) -> None:
    with make_client(tmp_path, live_session_ttl_s=2) as client:
        frame = next(blank_frames(1))
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            session_id = ws.receive_json()["session_id"]
            ws.send_bytes(encode(frame, 0, 1000))
            assert ws.receive_json()["frame"] == 0
        with client.websocket_connect("/live") as ws:
            ws.send_json({"type": "resume", "session_id": session_id})
            assert ws.receive_json()["resumed"]
            ws.send_bytes(encode(frame, 1, 999))
            assert ws.receive_json()["code"] == "bad_frame"
            ws.send_bytes(encode(frame, 1, 1e308)[:12] + b"corrupt JPEG")
            assert ws.receive_json()["code"] == "bad_frame"
            ws.send_bytes(encode(frame, 2, 1100))
            assert ws.receive_json()["frame"] == 3
            ws.send_bytes(encode(frame, 3, 1e308))
            assert ws.receive_json()["code"] == "capture_gap"
            assert ws.receive_json()["frame"] == 64


def test_live_session_streams_events_and_saves_a_job(tmp_path: Path) -> None:
    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json({**START, "court": "doubles"})
            started = ws.receive_json()
            assert started["type"] == "started" and not started["resumed"]
            assert (started["width"], started["height"]) == (640, 360)
            events = _send_frames(ws, 240)
            ws.send_json({"type": "stop"})
            tail = []
            while (e := ws.receive_json())["type"] != "saved":
                tail.append(e)
            saved = e
        assert saved["job_id"] == started["job_id"]
        assert client.get(f"/jobs/{started['job_id']}").status_code == 200
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
        before = client.get(f"/jobs/{job['id']}/record").json()
        response = client.post(f"/jobs/{job['id']}/render", json={"overlays": ["trail"]})
        assert response.status_code == 202
        assert _wait_done(client, job["id"])["status"] == "done"
        assert client.get(f"/jobs/{job['id']}/record").json() == before


def test_live_override_and_correction_over_the_socket(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json(START)
        assert ws.receive_json()["decision_ack"]
        events = _send_frames(ws, 230)
        call = next(e for e in events if e["type"] == "line_call")["line_call"]
        ws.send_json({"type": "override", "line_call_id": call["id"], "call": "out",
                      "decision_id": 11})  # fmt: skip
        update = ws.receive_json()
        assert update["type"] == "line_call" and update["line_call"]["override"]["call"] == "out"
        score = ws.receive_json()
        assert score["type"] == "score" and score["decision_id"] == 11
        assert ws.receive_json()["type"] == "coaching"
        ws.send_json({"type": "correct", "rally_index": 0, "winner": "far"})
        score = ws.receive_json()
        assert score["type"] == "score" and score["rallies"][0]["winner"] == "far"
        assert ws.receive_json()["type"] == "coaching"
        ws.send_json({"type": "override", "line_call_id": 99, "call": "in", "decision_id": 12})
        error = ws.receive_json()
        assert error["code"] == "not_found" and error["decision_id"] == 12


def test_resume_restores_open_rally_before_another_frame(tmp_path: Path) -> None:
    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            session_id = ws.receive_json()["session_id"]
            frame = _send_frames(ws, 46)[-1]
            assert frame["rally_state"] == "in_play"
        with client.websocket_connect("/live") as ws:
            ws.send_json({"type": "resume", "session_id": session_id})
            started = ws.receive_json()
            for key in ("rally_state", "rally_start_frame", "strokes_in_rally"):
                assert started[key] == frame[key]


def test_live_recovery_decisions_and_saved_replay(tmp_path: Path) -> None:
    import cv2

    from shuttlesense.coach.digest import build_digest
    from shuttlesense.schema import ClipRecord

    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json({**START, "best_of": 3, "first_server": "near"})
            session_id = ws.receive_json()["session_id"]
            _send_frames(ws, 1)
        with client.websocket_connect("/live") as ws:
            ws.send_json({"type": "resume", "session_id": session_id})
            started = ws.receive_json()
            assert started["resumed"] and started["frames"] == 1
            events = _send_frames(ws, 417, first=3)
            first = next(e for e in events if e["type"] == "frame")
            assert (first["frame"], first["time_s"]) == (3, 0.1)
            call = next(
                e["line_call"]
                for e in events
                if e["type"] == "line_call" and e["line_call"]["uncertain"]
            )
            ws.send_json({"type": "override", "line_call_id": call["id"], "call": "in",
                          "decision_id": 1})  # fmt: skip
            while (reply := ws.receive_json()).get("decision_id") != 1:
                pass
            corrected = reply["score"]
            assert ws.receive_json()["rally_summary"]["call"] == "in"
            ws.send_json({"type": "correct", "rally_index": call["rally_index"], "winner": None})
            cleared = ws.receive_json()
            assert cleared["rallies"][call["rally_index"]]["winner"] is None
            assert ws.receive_json()["type"] == "coaching"
            ws.send_json({"type": "undo"})
            assert ws.receive_json()["score"] == corrected
            assert ws.receive_json()["type"] == "coaching"
            # The replay is in its next rally now: an award would count that rally twice.
            ws.send_json({"type": "award", "winner": "far"})
            assert ws.receive_json()["code"] == "rally_in_play"
            ws.send_json({"type": "stop"})
            while (event := ws.receive_json())["type"] != "saved":
                pass
        job = _wait_done(client, event["job_id"])
        assert job["status"] == "done"
        history = client.get("/jobs").json()
        assert any(item["id"] == job["id"] and item["mode"] == "live" for item in history)
        record = ClipRecord.model_validate(client.get(f"/jobs/{job['id']}/record").json())
        assert record.score.model_dump(mode="json") == corrected
        assert record.num_frames == 420
        for frame in record.frames[1:3]:
            assert not frame.shuttle.visible and frame.shuttle_speed_kmh is None
        assert record.line_calls[call["id"]].effective_call == "in"
        digest = build_digest(record)
        assert f"Final score {corrected['near']}-{corrected['far']}" in digest.text
        playback = client.get(f"/jobs/{job['id']}/video")
        assert playback.status_code == 200
        replay = tmp_path / "replay.mp4"
        replay.write_bytes(playback.content)
        video = cv2.VideoCapture(str(replay))
        try:
            assert video.get(cv2.CAP_PROP_FRAME_COUNT) == record.num_frames
            assert video.get(cv2.CAP_PROP_FPS) == record.fps
            assert digest.moments
            for moment in digest.moments:
                assert moment.time_s == pytest.approx(moment.frame / record.fps, abs=0.001)
                assert video.set(cv2.CAP_PROP_POS_FRAMES, moment.frame)
                assert video.read()[0]
        finally:
            video.release()


def test_queue_overflow_leaves_unobserved_slots_in_the_record(tmp_path: Path, monkeypatch) -> None:
    from threading import Event

    from shuttlesense.api import live

    processing = Event()
    release = Event()
    overflowed = Event()
    frames = live._frames
    drop = live.LiveSession.drop

    def block_first_batch(session, batch):
        if not processing.is_set():
            processing.set()
            assert release.wait(5)
        return frames(session, batch)

    def observe_drop(session):
        drop(session)
        if session.stats.dropped == 5:
            overflowed.set()

    monkeypatch.setattr(live, "_frames", block_first_batch)
    monkeypatch.setattr(live.LiveSession, "drop", observe_drop)
    with make_client(tmp_path) as client:
        client.app.state.jobs.config["live"]["max_queue_frames"] = 2
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            ws.receive_json()
            packets = [encode(f, i, i * 1000 / 30) for i, f in enumerate(blank_frames(9))]
            ws.send_bytes(packets[0])
            try:
                assert processing.wait(5)
                for packet in packets[1:7]:
                    ws.send_bytes(packet)
                ws.send_json({"type": "award", "winner": "near", "decision_id": 1})
                ws.send_bytes(packets[7])  # cannot replace a frame across the award
                assert overflowed.wait(5)
            finally:
                release.set()
            assert [ws.receive_json()["frame"] for _ in range(3)] == [0, 5, 6]
            award = ws.receive_json()
            assert (award["type"], award["decision_id"], award["score"]["near"]) == ("score", 1, 1)
            assert award["score"]["corrections"][-1]["frame"] == 6
            ws.send_bytes(packets[8])
            while (frame := ws.receive_json())["type"] != "frame":
                assert frame["type"] != "error"
            assert frame["frame"] == 8
            ws.send_json({"type": "stop"})
            while (saved := ws.receive_json())["type"] != "saved":
                pass
            assert saved["stats"]["dropped"] == 5
        record = client.get(f"/jobs/{saved['job_id']}/record").json()
        assert record["num_frames"] == 9
        for frame in record["frames"][1:5]:
            assert not frame["shuttle"]["visible"] and frame["shuttle_speed_kmh"] is None


def test_started_snapshot_and_coaching_between_rallies(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json({**START, "start_score": {"near": 5, "far": 3}, "best_of": 3})
        started = ws.receive_json()
        assert (started["score"]["near"], started["score"]["far"]) == (5, 3)
        assert started["score"]["best_of"] == 3 and started["rallies"] == []
        assert started["coaching"] is None
        events = _send_frames(ws, 230)
        coaching = next(e for e in events if e["type"] == "coaching")
        summary = coaching["rally_summary"]
        assert summary["index"] == 0 and summary["strokes"] >= 1 and summary["duration_s"] > 0
        assert summary["call"] in ("in", "out") and isinstance(summary["faults"], list)
        assert all("hitter" in f for f in summary["faults"])
        assert "top_fixes" in coaching["coaching"]
        ws.send_json({"type": "stop"})
        while ws.receive_json()["type"] != "saved":
            pass


def test_live_award_clear_and_undo(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json({**START, "first_server": "near"})
        ws.receive_json()
        ws.send_json({"type": "undo"})
        assert ws.receive_json() == {"type": "error", "code": "not_found",
                                     "detail": "nothing to undo"}  # fmt: skip
        ws.send_json({"type": "correct", "rally_index": 0})
        assert ws.receive_json()["code"] == "bad_message"
        ws.send_json({"type": "award", "winner": "far"})
        score = ws.receive_json()["score"]
        assert (score["near"], score["far"]) == (0, 1) and score["server"] == "far"
        assert score["corrections"][0]["kind"] == "award"
        assert ws.receive_json()["type"] == "coaching"
        events = _send_frames(ws, 230)
        rally = next(e for e in events if e["type"] == "rally" and "rally" in e)["rally"]
        ws.send_json({"type": "correct", "rally_index": rally["index"], "winner": None})
        cleared = ws.receive_json()
        assert cleared["rallies"][rally["index"]]["winner"] is None
        assert ws.receive_json()["type"] == "coaching"
        ws.send_json({"type": "undo"})
        undone = ws.receive_json()
        assert undone["rallies"][rally["index"]]["winner"] == rally["winner"]
        assert ws.receive_json()["type"] == "coaching"
        ws.send_json({"type": "stop"})
        while (e := ws.receive_json())["type"] != "saved":
            pass
        record = client.get(f"/jobs/{e['job_id']}/record").json()
        assert [c["kind"] for c in record["score"]["corrections"]] == ["award"]


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
            assert started["score"] is not None and "hits" in started
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
        ({**START, "stroke_model": "svm"}, "bad_request"),
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


def test_invalid_referee_ids_cannot_change_a_rally_or_end_the_session(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json(START)
        ws.receive_json()
        for value in (0.5, True, "0", -1):
            ws.send_json({"type": "correct", "rally_index": value, "winner": "near"})
            assert ws.receive_json()["code"] == "bad_message"
            ws.send_json({"type": "override", "line_call_id": value, "call": "in"})
            assert ws.receive_json()["code"] == "bad_message"
        ws.send_text('{"type":"correct","rally_index":Infinity,"winner":"near"}')
        assert ws.receive_json()["code"] == "bad_message"
        ws.send_json({"type": "award", "winner": "far"})
        assert ws.receive_json()["score"]["far"] == 1
        assert ws.receive_json()["type"] == "coaching"
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
            ws.send_bytes(encode(next(blank_frames(1)), 3, 100))
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


@pytest.mark.parametrize(
    "change",
    [{"best_of": True}, {"best_of": 1.0}, {"best_of": 2}, {"name": 7}, {"name": "x" * 101}],
)
def test_start_rejects_loose_match_settings(change: dict) -> None:
    from shuttlesense.api.live import _start_request

    with pytest.raises(ValueError):
        _start_request({**START, **change})
    assert _start_request({**START, "best_of": 3}).best_of == 3


def test_start_accepts_the_doubles_first_server_and_receiver() -> None:
    from shuttlesense.api.live import _start_request

    req = _start_request({**START, "court": "doubles", "first_server_id": "near_2",
                          "first_receiver_id": "far_1"})  # fmt: skip
    assert (req.first_server, req.first_server_id, req.first_receiver_id) == (
        "near", "near_2", "far_1",
    )  # fmt: skip
    bad_starts = [
        {"first_server_id": "near_2"},
        {"first_server_id": "near_2", "first_receiver_id": "near_1"},
        {"first_server_id": "x", "first_receiver_id": "far_1"},
        # Service slots are for doubles only.
        {"court": "singles", "first_server_id": "near_1", "first_receiver_id": "far_1"},
    ]
    for bad in bad_starts:
        with pytest.raises(ValueError):
            _start_request({**START, **bad})


def test_live_service_message_names_a_later_games_server(tmp_path: Path) -> None:
    """D23 live: after game 1 the referee names who serves and receives first in game 2."""
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json({**START, "court": "doubles", "best_of": 3,
                      "first_server_id": "near_1", "first_receiver_id": "far_1"})  # fmt: skip
        assert ws.receive_json()["type"] == "started"
        ws.send_json({"type": "service", "game": 4, "server_id": "near_1",
                      "receiver_id": "far_1"})  # fmt: skip
        assert ws.receive_json()["code"] == "bad_request"
        for _ in range(21):
            ws.send_json({"type": "award", "winner": "near"})
            score = ws.receive_json()["score"]
            assert ws.receive_json()["type"] == "coaching"
        assert score["game"] == 2 and score.get("server_id") is None
        ws.send_json({"type": "service", "game": 2, "server_id": "near_2",
                      "receiver_id": "far_1"})  # fmt: skip
        score = ws.receive_json()["score"]
        assert (score["server_id"], score["receiver_id"]) == ("near_2", "far_1")
        ws.send_json({"type": "stop"})
        while ws.receive_json()["type"] != "saved":
            pass


def test_live_service_message_is_for_doubles_only(tmp_path: Path) -> None:
    with make_client(tmp_path) as client, client.websocket_connect("/live") as ws:
        ws.send_json(START)
        assert ws.receive_json()["type"] == "started"
        ws.send_json({"type": "service", "game": 2, "server_id": "near_1",
                      "receiver_id": "far_1"})  # fmt: skip
        assert ws.receive_json()["code"] == "bad_request"
        ws.send_json({"type": "stop"})
        while ws.receive_json()["type"] != "saved":
            pass


def test_fake_doubles_session_streams_four_players(tmp_path: Path) -> None:
    """T9.9: four players, partner hitters and the doubles service order over the socket."""
    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json({**START, "court": "doubles", "first_server_id": "near_1",
                          "first_receiver_id": "far_1"})  # fmt: skip
            started = ws.receive_json()
            assert started["score"]["server_id"] == "near_1"
            events = _send_frames(ws, 240)
            ws.send_json({"type": "stop"})
            while (e := ws.receive_json())["type"] != "saved":
                events.append(e)
        frame = next(e for e in events if e["type"] == "frame")
        assert {"near", "far", "near_2", "far_2"} <= set(frame["players"])
        hits = [e["hit"] for e in events if e["type"] == "hit"]
        assert hits and {h["hitter"] for h in hits} <= {"near_1", "far_1"}
        job = _wait_done(client, e["job_id"])
        assert job["court"] == "doubles" and job["first_server_id"] == "near_1"
        record = client.get(f"/jobs/{e['job_id']}/record").json()
        assert record["rallies"][0]["server_id"] == "near_1"
        assert "near_1" in record["summary"]["per_player"]


def test_live_start_takes_a_stroke_model() -> None:
    from shuttlesense.api.live import _start_request
    from shuttlesense.config import with_stroke_model

    assert _start_request(dict(START)).stroke_model is None  # the server's default
    assert _start_request({**START, "stroke_model": "rf"}).stroke_model == "rf"
    assert with_stroke_model({}, "rf") == {"stages": {"strokes": {"algorithm": "rf"}}}
