from __future__ import annotations

import numpy as np

from shuttlesense.hits import detect_hits
from shuttlesense.hits import run as hits_run
from shuttlesense.schema import ClipRecord, Frame, Player, Shuttle
from shuttlesense.stage import StageContext

CFG = {"min_angle_deg": 60, "max_wrist_distance_px": 50, "min_frames_between_hits": 5}


def bounce_track(turns: list[int], n: int = 40) -> np.ndarray:
    """Shuttle going right, reversing direction at each frame in `turns`."""
    xy = np.zeros((n, 2))
    x, dx = 100.0, 10.0
    for i in range(n):
        if i in turns:
            dx = -dx
        x += dx
        xy[i] = x, 200.0
    return xy


def wrists_at(n: int, frames: dict[int, tuple[float, float]]) -> list[np.ndarray | None]:
    out: list[np.ndarray | None] = [None] * n
    for f, (x, y) in frames.items():
        out[f] = np.array([[x, y, 0.9], [x + 300, y, 0.9]])
    return out


def test_detects_hit_at_direction_change_near_wrist() -> None:
    xy = bounce_track([10])
    visible = np.ones(40)
    near = wrists_at(40, {9: tuple(xy[9])})
    assert detect_hits(xy, visible, near, [None] * 40, CFG) == [(9, "near")]


def test_ignores_direction_change_far_from_players() -> None:
    xy = bounce_track([10])
    far_away = wrists_at(40, {9: (xy[9][0] + 200, 200.0)})
    assert detect_hits(xy, np.ones(40), far_away, [None] * 40, CFG) == []


def test_min_gap_suppresses_duplicates() -> None:
    xy = bounce_track([10, 12])
    near = wrists_at(40, {9: tuple(xy[9] + [5, 0]), 11: tuple(xy[11] + [20, 0])})
    hits = detect_hits(xy, np.ones(40), near, wrists_at(40, {}), CFG)
    assert hits == [(9, "near")]  # 11 is within the gap and farther from the wrist


def test_hits_alternate_players() -> None:
    xy = bounce_track([10, 20, 30])
    near = wrists_at(40, {9: tuple(xy[9] + [30, 0]), 19: tuple(xy[19] + [5, 0])})
    far = wrists_at(40, {29: tuple(xy[29])})
    hits = detect_hits(xy, np.ones(40), near, far, CFG)
    assert hits == [(19, "near"), (29, "far")]


def test_jump_across_unfilled_gap_is_not_a_hit() -> None:
    # Moving right, lost for frames 10-24, back further left still moving right: the jump
    # across the gap looks like two reversals but the shuttle never turned.
    xy = np.array([[100.0 + 10 * i, 200.0] for i in range(40)])
    xy[25:] -= 250.0
    visible = np.ones(40)
    visible[10:25] = 0
    near = wrists_at(40, {9: tuple(xy[9]), 25: tuple(xy[25])})
    assert detect_hits(xy, visible, near, [None] * 40, CFG) == []
    # A real turn right after the gap is still found.
    xy2 = xy.copy()
    xy2[31:, 0] = xy2[30, 0] - 10 * np.arange(1, 10)
    near2 = wrists_at(40, {30: tuple(xy2[30])})
    assert detect_hits(xy2, visible, near2, [None] * 40, CFG) == [(30, "near")]


def test_stage_fills_record_hits() -> None:
    xy = bounce_track([10])
    frames = [Frame(frame=i, shuttle=Shuttle(x=x, y=y, visible=1)) for i, (x, y) in enumerate(xy)]
    kps = [(0.0, 0.0, 0.0)] * 17
    kps[9] = (xy[9][0], xy[9][1], 0.9)
    frames[9].players.near = Player(bbox=(0, 0, 10, 10), keypoints=kps)
    record = ClipRecord(clip_id="c", fps=20, width=1280, height=720, num_frames=40, frames=frames)
    ctx = StageContext(video_path=None, out_dir=None, config={"stages": {"hits": CFG}})
    record = hits_run(record, ctx)
    assert [(h.id, h.frame, h.time_s, h.player) for h in record.hits] == [(0, 9, 0.45, "near")]


def test_same_player_may_hit_again_after_a_rally_break() -> None:
    """The winner of a rally serves the next one, so alternation resets across a break."""
    from shuttlesense.config import load_config
    from shuttlesense.hits import run as hits_run
    from shuttlesense.stage import StageContext
    from shuttlesense.stream.synthetic import synthetic_record

    record, truth = synthetic_record()
    ctx = StageContext(video_path=None, out_dir=None, config=load_config())
    hits_run(record, ctx)
    assert [(h.frame, h.player) for h in record.hits] == [(f, s) for f, s, _ in truth["hits"]]
    # Near hit the last shot of rally 1 (frame 45) and serves rally 2 (frame 132).
    assert (45, "near") in [(h.frame, h.player) for h in record.hits]
    assert (132, "near") in [(h.frame, h.player) for h in record.hits]
