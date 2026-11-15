import json
from datetime import UTC, datetime, timedelta

import pytest

from shuttlesense.analytics.export import keep_chat, write_exports
from shuttlesense.api.live import _control
from shuttlesense.config import load_config
from shuttlesense.courtside import control_interval, set_goal, sync_interval
from shuttlesense.schema import ClipRecord, PracticeGoal, Score, load_record
from shuttlesense.stream.perception import ReplayPerception
from shuttlesense.stream.session import LiveSession, StartRequest
from shuttlesense.stream.synthetic import synthetic_record


def session():
    record, _ = synthetic_record()
    return LiveSession(
        session_id="test",
        request=StartRequest(fps=30, width=640, height=360),
        config=load_config(),
        perception=ReplayPerception(record, (640, 360)),
        court_corners=None,
        recording=None,
    )


def test_duplicate_decisions_are_session_and_client_scoped():
    live = session()
    command = {"type": "award", "winner": "near", "client_id": "a", "decision_id": 1}
    assert _control(live, command)[0]["score"]["near"] == 1
    assert _control(live, command)[0]["score"]["near"] == 1
    assert _control(live, {**command, "winner": "far"})[0]["code"] == "decision_conflict"
    assert _control(live, {**command, "client_id": "b"})[0]["score"]["near"] == 2
    # A retry returns current state, never the old score cached with the receipt.
    assert _control(live, command)[0]["score"]["near"] == 2
    undo = {"type": "undo", "client_id": "a", "decision_id": 2}
    assert _control(live, undo)[0]["score"]["near"] == 1
    assert _control(live, undo)[0]["score"]["near"] == 1
    assert _control(session(), command)[0]["score"]["near"] == 1


def test_audit_history_retains_undone_decisions_and_ignores_errors():
    live = session()
    _control(live, {"type": "award", "winner": "near", "reason": "service_fault"})
    _control(live, {"type": "concede", "winner": "far"})
    _control(live, {"type": "award", "winner": "near"})  # refused after match end
    _control(live, {"type": "undo"})
    entries = live.analyzer.record.decision_log
    assert [e.kind for e in entries] == ["award", "concede", "undo"]
    assert entries[0].reason == "service_fault" and not entries[0].undone
    assert entries[1].undone and entries[2].undoes == entries[1].id
    assert live.analyzer.record.score.match_winner is None


def test_interval_clock_is_explicit_pausable_and_does_not_score():
    record = session().analyzer.record
    record.score = Score(near=11, far=8, interval=True, interval_s=60)
    now = datetime(2026, 11, 15, tzinfo=UTC)
    assert sync_interval(record, now).status == "ready"
    assert sync_interval(record, now + timedelta(seconds=90)).remaining_s == 60
    control_interval(record, "start", now)
    control_interval(record, "pause", now + timedelta(seconds=10))
    assert sync_interval(record, now + timedelta(seconds=100)).remaining_s == 50
    control_interval(record, "resume", now + timedelta(seconds=100))
    assert sync_interval(record, now + timedelta(seconds=151)).status == "complete"
    assert (record.score.near, record.score.far) == (11, 8)
    control_interval(record, "reset", now)
    assert record.interval_state.status == "ready"
    control_interval(record, "end", now)
    assert record.interval_state.status == "ended"
    record.score.interval = False
    assert sync_interval(record, now) is None
    with pytest.raises(ValueError):
        control_interval(record, "start", now)


def test_interval_transition_is_cancelled_by_undo():
    live = session()
    for _ in range(11):
        _control(live, {"type": "award", "winner": "near"})
    result = _control(live, {"type": "interval", "action": "start"})
    assert result[0]["interval_state"]["status"] == "running"
    result = _control(live, {"type": "undo"})
    assert result[0]["interval_state"] is None


def test_goals_and_history_survive_save_reload_and_rerender(tmp_path):
    live = session()
    _control(live, {"type": "award", "winner": "near"})
    goal = {"text": " Recover to base ", "player": "near"}
    result = _control(live, {"type": "goal", "goal": goal})
    assert result[0]["practice_goals"][0]["text"] == "Recover to base"
    record = live.analyzer.record
    write_exports(record, tmp_path)
    rebuilt = ClipRecord(clip_id="test", fps=30, width=640, height=360, num_frames=0)
    keep_chat(rebuilt, tmp_path)
    write_exports(rebuilt, tmp_path)
    saved = load_record((tmp_path / "record.json").read_text())
    assert saved.practice_goals == record.practice_goals
    assert saved.decision_log == record.decision_log
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert "self-reported" in summary["coaching_recap"]["goal_evidence"]
    assert summary["coaching_recap"]["practice_goals"][0]["player"] == "near"


def test_goal_validation_and_filter_replacement():
    record = session().analyzer.record
    set_goal(record, PracticeGoal(text="Near goal", player="near"))
    set_goal(record, PracticeGoal(text="Far goal", player="far"))
    set_goal(record, PracticeGoal(text="Replacement", player="near", completed=True))
    assert len(record.practice_goals) == 2
    assert record.practice_goals[-1].completed
    for goal in [
        PracticeGoal(text=" "),
        PracticeGoal(text="Bad rally", rally_index=2),
        PracticeGoal(text="Partner", player="near_2"),
    ]:
        with pytest.raises(ValueError):
            set_goal(record, goal)
    set_goal(record, PracticeGoal(text="Partner", player="near_2"), doubles=True)
    assert record.practice_goals[-1].player == "near_2"


def test_old_record_does_not_invent_history():
    record = load_record(
        '{"schema_version":"1.5","clip_id":"old","fps":30,"width":640,"height":360,"num_frames":0}'
    )
    assert record.schema_version == "1.7"
    assert record.practice_goals == record.decision_log == []
    assert record.interval_state is None


def test_reconnect_restores_goals_history_and_command_receipts(tmp_path):
    from test_live import START, make_client

    with make_client(tmp_path, live_session_ttl_s=10) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            started = ws.receive_json()
            command = {"type": "award", "winner": "near", "client_id": "phone", "decision_id": 1}
            ws.send_json(command)
            reply = ws.receive_json()
            assert reply["score"]["near"] == 1
        with client.websocket_connect("/live") as ws:
            ws.send_json({"type": "resume", "session_id": started["session_id"]})
            resumed = ws.receive_json()
            assert resumed["courtside_depth"] and resumed["decision_dedup"]
            assert len(resumed["decision_log"]) == 1
            ws.send_json(command)
            assert ws.receive_json()["score"]["near"] == 1
            ws.send_json(
                {
                    "type": "goal",
                    "decision_id": 2,
                    "client_id": "phone",
                    "goal": {"text": "Recover to base"},
                }
            )
            assert ws.receive_json()["practice_goals"][0]["text"] == "Recover to base"


def test_saved_goal_endpoint_and_exports(tmp_path, tiny_video):
    from test_api import make_client, upload, wait_for

    with make_client(tmp_path, fake_pipeline=True) as client:
        video = upload(client, tiny_video).json()
        job = client.post("/jobs", json={"video_id": video["id"]}).json()
        assert wait_for(client, job["id"])["status"] == "done"
        url = f"/jobs/{job['id']}"
        goal = {"text": "Stay balanced", "completed": True}
        result = client.put(url + "/practice-goal", json=goal)
        assert result.status_code == 200, result.text
        assert result.json()["practice_goals"][0]["completed"]
        assert client.put(url + "/practice-goal", json={"text": " "}).status_code == 422
        exported = client.get(url + "/summary.json").json()
        assert exported["coaching_recap"]["practice_goals"][0]["text"] == "Stay balanced"


def test_stop_preserves_decisions_and_goals_without_decodable_frames(tmp_path):
    from test_live import START, make_client

    with make_client(tmp_path) as client:
        with client.websocket_connect("/live") as ws:
            ws.send_json(START)
            job_id = ws.receive_json()["job_id"]
            ws.send_json({"type": "award", "winner": "near"})
            assert ws.receive_json()["decision_log"][0]["frame"] is None
            assert ws.receive_json()["type"] == "coaching"
            ws.send_json({"type": "goal", "goal": {"text": "Recover to base"}})
            assert ws.receive_json()["practice_goals"]
            ws.send_json({"type": "stop"})
            assert ws.receive_json()["job_id"] == job_id
        job = client.get(f"/jobs/{job_id}").json()
        assert job["outputs"]["record"] and not job["outputs"]["video"]
        record = client.get(f"/jobs/{job_id}/record").json()
        assert record["num_frames"] == 0
        assert record["practice_goals"][0]["text"] == "Recover to base"
        assert record["decision_log"][0]["frame"] is None
