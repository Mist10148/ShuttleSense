from __future__ import annotations

import numpy as np
import pytest

from shuttlesense import analytics, feedback, hits, referee
from shuttlesense.config import load_config
from shuttlesense.stage import StageContext
from shuttlesense.stream.analyzer import StreamAnalyzer, planned_classifier
from shuttlesense.stream.perception import ReplayPerception
from shuttlesense.stream.session import LiveSession, StartRequest, normalized_size
from shuttlesense.stream.synthetic import CORNERS, synthetic_record

CONFIG = load_config()


def _offline(record):
    record = record.model_copy(deep=True)
    ctx = StageContext(video_path=None, out_dir=None, config=CONFIG)
    for stage in (hits, feedback, analytics, referee):
        stage.run(record, ctx)
    return record


def _live(record, **kwargs):
    a = StreamAnalyzer(clip_id="live", fps=record.fps, width=record.width, height=record.height,
                       court=record.court, config=CONFIG, **kwargs)  # fmt: skip
    events = []
    for f in record.frames:
        events += a.add_frame(f.shuttle, f.players)
    return a, a.finalize(), events


def test_offline_live_parity() -> None:
    record, truth = synthetic_record()
    off = _offline(record)
    _, live, _ = _live(record)
    assert [(h.frame, h.player) for h in live.hits] == [(h.frame, h.player) for h in off.hits]
    assert [(h.frame, h.player) for h in off.hits] == [(f, s) for f, s, _ in truth["hits"]]
    key = [(r.start_frame, r.end_frame, r.winner) for r in off.rallies]
    assert [(r.start_frame, r.end_frame, r.winner) for r in live.rallies] == key
    calls = [(c.frame, c.call, c.uncertain) for c in off.line_calls]
    assert [(c.frame, c.call, c.uncertain) for c in live.line_calls] == calls
    assert calls == [(63, "in", False), (204, "out", False), (327, "in", True)]
    assert (live.score.near, live.score.far) == (off.score.near, off.score.far)
    assert live.mode == "live" and live.rally_events and live.summary.total_hits == 10


def test_a_long_rally_keeps_its_start_when_the_window_slides() -> None:
    record, _ = synthetic_record()
    off = _offline(record)
    # A window shorter than a rally plus its settle time: the window slides into each rally.
    _, live, events = _live(record, max_window_frames=100)
    assert [r.start_frame for r in live.rallies] == [r.start_frame for r in off.rallies]
    in_play = [e for e in events if e["type"] == "rally" and e["state"] == "in_play"]
    assert len(in_play) == len(off.rallies)


def test_events_arrive_in_order_and_lag_is_bounded() -> None:
    record, truth = synthetic_record()
    a, _, events = _live(record)
    frames = [e for e in events if e["type"] == "frame"]
    assert len(frames) == len(record.frames)
    # A hit is announced once its look-ahead has passed, never later than a tick after that.
    seen = 0
    for e in events:
        if e["type"] == "frame":
            seen = e["frame"]
        if e["type"] == "hit":
            assert a.hit_lag <= seen - e["hit"]["frame"] < a.hit_lag + a.tick_every
        if e["type"] == "rally" and e["state"] == "between_rallies" and seen < len(frames) - 1:
            # Final only once a hit that would merge it with the next rally is ruled out.
            assert seen - e["rally"]["end_frame"] >= a.rally_settle
    kinds = [e["type"] for e in events if e["type"] != "frame"]
    assert kinds.count("line_call") == 3 and kinds.count("score") == 3
    in_play = [e for e in events if e["type"] == "rally" and e["state"] == "in_play"]
    # Same starts as offline: the first rally counts from frame 0 (the toss is in view).
    assert [e["start_frame"] for e in in_play] == [0, 132, 273]


def test_override_and_correction_rescore() -> None:
    record, _ = synthetic_record()
    a, live, _ = _live(record)
    uncertain = next(c for c in live.line_calls if c.uncertain)
    assert live.rallies[uncertain.rally_index].winner is None
    events = a.override(uncertain.id, "out")
    assert events[0]["line_call"]["override"]["call"] == "out"
    # The far player hit the last shot of that rally out.
    assert a.record.rallies[uncertain.rally_index].winner == "near"
    assert events[1]["score"]["near"] == 3
    a.correct(0, "far")
    assert (a.record.score.near, a.record.score.far) == (2, 1)
    with pytest.raises(KeyError):
        a.override(99, "in")


def test_referee_decisions_refresh_latest_coaching_summary() -> None:
    record, _ = synthetic_record()
    a, live, _ = _live(record)
    last = live.rallies[-1]
    call = next(c for c in live.line_calls if c.rally_index == last.index)
    events = a.override(call.id, "out")
    assert events[-1]["type"] == "coaching"
    assert events[-1]["rally_summary"]["call"] == "out"
    events = a.correct(last.index, "far")
    assert events[-1]["rally_summary"]["winner"] == "far"
    events = a.undo()
    assert events[-1]["rally_summary"]["winner"] == a.record.rallies[-1].winner


def test_resume_snapshot_contains_latest_rally_summary() -> None:
    from shuttlesense.api.live import _snapshot

    record, _ = synthetic_record()
    analyzer, live, _ = _live(record)
    session = _session(30)
    session.analyzer = analyzer
    snapshot = _snapshot(session)
    assert snapshot["rally_summary"]["index"] == live.rallies[-1].index
    assert snapshot["rally_summary"]["winner"] == live.rallies[-1].winner


def test_planned_classifier_labels_hits() -> None:
    from shuttlesense.stream.synthetic import planned_strokes

    record, truth = synthetic_record()
    _, live, _ = _live(record, classify=planned_classifier(planned_strokes(truth)))
    assert [h.stroke for h in live.hits][:3] == ["serve", "clear", "smash"]


def test_replay_perception_scales_to_the_session() -> None:
    record, _ = synthetic_record()
    p = ReplayPerception(record, (640, 360))
    shuttle, players = p(np.zeros((360, 640, 3), np.uint8), 10)
    src = record.frames[10].shuttle
    assert shuttle.x == pytest.approx(src.x / 2, abs=0.01)
    assert shuttle.y == pytest.approx(src.y / 2, abs=0.01)
    assert players.near.bbox[3] == pytest.approx(record.frames[10].players.near.bbox[3] / 2)


def _session(fps: float, tmp_path=None) -> LiveSession:
    record, _ = synthetic_record()
    return LiveSession(
        session_id="s", request=StartRequest(fps=fps, width=640, height=360), config=CONFIG,
        perception=ReplayPerception(record, (640, 360)), court_corners=None,
        recording=tmp_path / "rec.mp4" if tmp_path else None,
    )  # fmt: skip


def test_live_court_uses_the_configured_court_size() -> None:
    record, _ = synthetic_record()
    doubles = {**CONFIG, "stages": {**CONFIG["stages"], "court": {"court_size_m": [6.1, 13.4]}}}
    session = LiveSession(
        session_id="s", request=StartRequest(fps=30, width=640, height=360), config=doubles,
        perception=ReplayPerception(record, (640, 360)), court_corners=CORNERS, recording=None,
    )  # fmt: skip
    court = session.analyzer.record.court
    assert court is not None and tuple(court.court_size_m) == (6.1, 13.4)


def test_a_faster_camera_is_thinned_to_max_fps() -> None:
    from shuttlesense.stream.fake_source import blank_frames, encode

    session = _session(60)
    assert session.fps == 30
    for i, frame in enumerate(blank_frames(60)):
        ts = i * 1000 / 60
        session.process(encode(frame, i, ts)[12:], i, ts, 0.0)
    assert session.analyzer.record.num_frames == 30 and session.stats.dropped == 30
    # A camera at or under the cap keeps every frame, even with jittery timestamps.
    slow = _session(25)
    for i in range(10):
        assert slow.admit(i * 40 + (5 if i % 2 else -5))


def test_skipped_frames_do_not_run_the_windowed_stages(monkeypatch) -> None:
    from shuttlesense.stream.fake_source import blank_frames, encode

    session = _session(30)
    ticks = []
    monkeypatch.setattr(session.analyzer, "_tick", lambda now, final: ticks.append(now) or [])
    frames = [encode(f, i, i * 33.3)[12:] for i, f in enumerate(blank_frames(12))]
    for i in range(9):
        session.skip(frames[i], i, i * 33.3)
    assert ticks == []
    session.process(frames[9], 9, 9 * 33.3, 0.0)
    assert ticks == [9]


def test_skipped_frames_are_passed_to_referee_in_window_coordinates(monkeypatch) -> None:
    from shuttlesense import analytics, hits, referee
    from shuttlesense.schema import Players, Shuttle

    analyzer = _session(30).analyzer
    analyzer.tick_every = 100
    for i in range(6):
        analyzer.add_frame(Shuttle(), Players(), tick=i != 3)
    analyzer.anchor = 2
    seen = []
    monkeypatch.setattr(hits, "run", lambda record, ctx: record)
    monkeypatch.setattr(analytics, "run", lambda record, ctx: record)
    monkeypatch.setattr(referee, "run", lambda record, ctx: seen.append(ctx.config))
    analyzer._run_stages(analyzer._window(2, 5))
    assert seen[0]["_unobserved_frames"] == {1}


def test_model_perception_returns_full_size_players_for_a_small_frame() -> None:
    from shuttlesense.pose.tracking import PlayerTracker
    from shuttlesense.schema import COURT_SIZE_M, NUM_KEYPOINTS, Player
    from shuttlesense.stream.perception import ModelPerception

    person = Player(bbox=(100, 100, 20, 60), keypoints=[(110, 110, 0.9)] * NUM_KEYPOINTS,
                    score=0.9)  # fmt: skip
    p = ModelPerception.__new__(ModelPerception)  # no models: set only what _players uses
    p.size, p.model, p.detect = (640, 360), None, lambda frame: [person]
    p.min_person_score, p.homography, p.court_size = 0.4, None, COURT_SIZE_M
    p.tracker = PlayerTracker()
    _, players = p(np.zeros((180, 320, 3), np.uint8), 0)  # half-size frame
    seen = players.near or players.far
    assert seen.bbox == pytest.approx((200, 200, 40, 120))
    assert seen.keypoints[0][:2] == pytest.approx((220, 220))


def test_normalized_size_matches_io() -> None:
    assert normalized_size(1920, 1080, 720) == (1280, 720)
    assert normalized_size(641, 361, 720) == (640, 360)


class SlowPerception:
    available = {"tracking": True, "pose": True}

    def __init__(self, record, size) -> None:
        self.replay = ReplayPerception(record, size)

    def __call__(self, frame, index):
        import time

        time.sleep(0.02)
        return self.replay(frame, index)


def test_session_degrades_when_over_budget(tmp_path) -> None:
    from shuttlesense.stream.fake_source import blank_frames, encode

    record, _ = synthetic_record()
    config = {**CONFIG, "live": {"budget_ms": 5, "check_every": 10}}
    corners = [(x / 2, y / 2) for x, y in CORNERS]
    session = LiveSession(
        session_id="s", request=StartRequest(fps=30, width=640, height=360), config=config,
        perception=SlowPerception(record, (640, 360)), court_corners=corners,
        recording=tmp_path / "rec.mp4",
    )  # fmt: skip
    import time

    events = []
    for i, frame in enumerate(blank_frames(25)):
        data = encode(frame, i, 0.0)
        events += session.process(data[12:], i, 0.0, time.monotonic())
    degraded = [e for e in events if e["type"] == "degraded"]
    assert degraded and degraded[0]["level"] == 1 and "budget" in degraded[0]["reason"]
    assert session.level == 2  # two checks over budget
    frame_events = [e for e in events if e["type"] == "frame"]
    assert all("latency_ms" in e for e in frame_events)
    # Frames processed at half size still carry full-size coordinates.
    replay = ReplayPerception(record, (640, 360))
    for f in session.analyzer.record.frames[-5:]:
        expected, players = replay(None, f.frame)
        got = (f.shuttle.visible, f.shuttle.x, f.shuttle.y)
        assert got == (expected.visible, expected.x, expected.y)
        assert f.players.near.bbox == pytest.approx(players.near.bbox)
    session.skip(encode(next(blank_frames(1)), 25, 0.0)[12:], 25, 0.0)
    record = session.finish()
    assert record.num_frames == 26 and session.stats.skipped == 1
    assert (tmp_path / "rec.mp4").stat().st_size > 0
