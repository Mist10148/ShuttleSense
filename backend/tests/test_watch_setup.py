from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.match_type import detect_match_type, suggest_counts
from shuttlesense.api.settings import Settings
from shuttlesense.schema import ClipRecord, Frame, Hit, Player, Players, Shuttle
from shuttlesense.stream.watch_strokes import guard_hits, sufficient_evidence


@pytest.mark.parametrize(
    ("counts", "expected"),
    [
        ([(2, 2)] * 3 + [(1, 1)] * 9, "doubles"),
        ([(1, 1)] * 8 + [(0, 0)] * 4, "singles"),
        ([(1, 1)] * 10 + [(2, 2)], None),
        ([(1, 0)] * 12, None),
        ([], None),
    ],
)
def test_suggestions_require_consistent_evidence(counts, expected):
    assert suggest_counts(counts)["suggestion"] == expected


def test_video_scan_uses_court_sides_and_ignores_off_court(tiny_video: Path, monkeypatch):
    def person(x, foot_y):
        return Player(bbox=(x - 4, foot_y - 10, 8, 10), score=1)

    players = [person(65, 70), person(95, 70), person(65, 30), person(95, 30), person(1, 1)]
    monkeypatch.setattr(
        "shuttlesense.pose.estimator.load_detector", lambda *args: lambda _: players
    )
    corners = [[30, 80], [130, 80], [110, 10], [50, 10]]
    result = detect_match_type(tiny_video, corners, {}, "cpu")
    assert result["suggestion"] == "doubles"
    assert result["sampled_frames"] == 10


def test_match_type_endpoint_validates_busy_and_demo(tmp_path: Path, tiny_video: Path, monkeypatch):
    app = create_app(Settings(storage_dir=tmp_path / "storage", device="cpu", fake_pipeline=False))
    corners = [[30, 80], [130, 80], [110, 10], [50, 10]]
    monkeypatch.setattr(
        "shuttlesense.api.match_type.detect_match_type",
        lambda *args: {"suggestion": "doubles", "detail": "estimate"},
    )
    with TestClient(app) as client:
        with tiny_video.open("rb") as f:
            video = client.post("/videos", files={"file": ("tiny.mp4", f, "video/mp4")}).json()
        url = "/videos/" + video["id"] + "/match-type"
        assert client.post(url, json={"corners": corners}).json()["suggestion"] == "doubles"
        assert client.post(url, json={"corners": [[0, 0]] * 4}).status_code == 400
        app.state.jobs.gpu.acquire()
        try:
            assert client.post(url, json={"corners": corners}).status_code == 409
        finally:
            app.state.jobs.gpu.release()
    demo = create_app(Settings(storage_dir=tmp_path / "demo", device="cpu", fake_pipeline=True))
    with TestClient(demo) as client:
        assert client.get("/health").json()["watch_match_type"] is False
        assert (
            client.post("/videos/123456789012/match-type", json={"corners": corners}).status_code
            == 503
        )


def test_stroke_guard_requires_full_window_observations_and_confidence():
    player = Player(bbox=(0, 0, 100, 100), keypoints=[(40, 45, 1)] * 17, score=1)
    frames = [
        Frame(frame=i, players=Players(near=player), shuttle=Shuttle(x=20, y=20, visible=1))
        for i in range(40)
    ]
    rec = ClipRecord(clip_id="test", fps=30, width=100, height=100, num_frames=40, frames=frames)
    hit = Hit(id=0, frame=20, time_s=20 / 30, player="near", stroke="smash", confidence=0.8)
    ckpt = {"window_frames": 30, "use_trajectory": True}
    assert sufficient_evidence(rec, hit, ckpt)
    assert not sufficient_evidence(rec, hit, ckpt, unobserved=set(range(5, 35)))
    hit.confidence = 0.49
    assert not sufficient_evidence(rec, hit, ckpt)
    hit.confidence = 0.8
    hit.frame = 2
    assert not sufficient_evidence(rec, hit, ckpt)
    hit.frame = 20
    for frame in rec.frames:
        frame.shuttle = Shuttle()
    assert not sufficient_evidence(rec, hit, ckpt)
    rec.hits = [hit]
    guard_hits(rec, ckpt)
    assert hit.stroke is None and hit.confidence is None and hit.feedback == []


def test_stroke_guard_handles_missing_pose_and_uncertain_doubles_hitter():
    player = Player(bbox=(0, 0, 100, 100), keypoints=[(40, 45, 1)] * 17, score=1)
    frames = [
        Frame(frame=i, players=Players(near=player), shuttle=Shuttle(x=20, y=20, visible=1))
        for i in range(40)
    ]
    rec = ClipRecord(clip_id="test", fps=30, width=100, height=100, num_frames=40, frames=frames)
    hit = Hit(id=0, frame=20, time_s=20 / 30, player="near", stroke="smash", confidence=0.8)
    rec.hits = [hit]
    ckpt = {"window_frames": 30, "use_trajectory": True}
    guard_hits(rec, ckpt, doubles=True)
    assert hit.stroke is None
    hit.stroke, hit.confidence = "smash", 0.8
    for frame in rec.frames:
        frame.players.near = None
    assert not sufficient_evidence(rec, hit, ckpt)
