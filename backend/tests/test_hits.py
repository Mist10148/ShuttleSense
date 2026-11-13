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


def test_frames_live_mode_skipped_do_not_split_a_run() -> None:
    """Live: every other frame got no perception. Those gaps are not the shuttle out of view."""
    xy = bounce_track([11])
    visible = np.ones(40)
    skipped = set(range(1, 40, 2))
    visible[list(skipped)] = 0
    near = wrists_at(40, {10: tuple(xy[10])})
    # Without the skipped frames every gap splits the track into runs of one point.
    assert detect_hits(xy, visible, near, [None] * 40, CFG) == []
    assert detect_hits(xy, visible, near, [None] * 40, CFG, unobserved=skipped) == [(10, "near")]


def test_skipped_frames_are_not_a_rally_break() -> None:
    """Two near hits with only skipped frames between are one rally: keep the closer one."""
    cfg = {**CFG, "rally_break_frames": 5}
    xy = bounce_track([11, 31])
    visible = np.ones(40)
    skipped = set(range(15, 25))
    visible[list(skipped)] = 0
    near = wrists_at(40, {10: tuple(xy[10] + [10, 0]), 30: tuple(xy[30])})
    assert len(detect_hits(xy, visible, near, [None] * 40, cfg)) == 2  # seen as a break
    assert detect_hits(xy, visible, near, [None] * 40, cfg, unobserved=skipped) == [(30, "near")]


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


# Doubles hitter attribution (T9.5) ----------------------------------------------------------


def _with_wrist(x: float, y: float, score: float = 0.9) -> Player:
    kps = [(x, y, 0.0)] * 17
    kps[9] = (x, y, score)
    kps[10] = (x, y, score)
    return Player(bbox=(x - 20, y - 60, 40, 120), keypoints=kps, score=0.9)


def _doubles_record(near_1_x: float, near_2_x: float, shuttle_x: float = 300.0) -> ClipRecord:
    from shuttlesense.schema import Hit, Players

    frames = [
        Frame(frame=i, shuttle=Shuttle(x=shuttle_x, y=400.0, visible=1),
              players=Players(near=_with_wrist(near_1_x, 400.0),
                              near_2=_with_wrist(near_2_x, 400.0)))
        for i in range(10)
    ]  # fmt: skip
    return ClipRecord(clip_id="d", fps=30, width=1280, height=720, num_frames=10, frames=frames,
                      hits=[Hit(id=0, frame=5, time_s=0.17, player="near")])  # fmt: skip


def test_doubles_hit_goes_to_the_closer_partner() -> None:
    from shuttlesense.hits.detector import attribute_hitters

    record = _doubles_record(near_1_x=310, near_2_x=600)
    attribute_hitters(record, {})
    hit = record.hits[0]
    assert hit.hitter == "near_1" and hit.player_attr == "near"
    assert 0.5 < hit.hitter_confidence <= 0.99
    record = _doubles_record(near_1_x=900, near_2_x=290)
    attribute_hitters(record, {})
    assert record.hits[0].hitter == "near_2" and record.hits[0].player_attr == "near_2"


def test_doubles_hitter_is_unknown_when_both_partners_are_as_close() -> None:
    from shuttlesense.hits.detector import attribute_hitters

    record = _doubles_record(near_1_x=290, near_2_x=310)
    attribute_hitters(record, {"ambiguous_px": 25})
    assert record.hits[0].hitter is None and record.hits[0].hitter_confidence is None


def test_singles_hits_get_no_hitter() -> None:
    from shuttlesense.hits.detector import attribute_hitters
    from shuttlesense.schema import Players

    record = _doubles_record(near_1_x=310, near_2_x=600)
    for f in record.frames:
        f.players = Players(near=f.players.near)
    attribute_hitters(record, {})
    assert record.hits[0].hitter is None


def test_doubles_side_wrists_include_the_partner() -> None:
    from shuttlesense.hits.detector import wrist_arrays

    record = _doubles_record(near_1_x=310, near_2_x=600)
    assert wrist_arrays(record, "near")[0].shape == (4, 3)
    assert wrist_arrays(record, "near_2")[0].shape == (2, 3)
    assert wrist_arrays(record, "far")[0] is None
