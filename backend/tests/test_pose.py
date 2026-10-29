from __future__ import annotations

import numpy as np

from shuttlesense.court import compute_homography
from shuttlesense.pose.tracking import (
    PlayerTracker,
    bbox_from_keypoints,
    filter_players,
    smooth_keypoints,
)
from shuttlesense.schema import Player

CORNERS = [[212, 650], [1068, 650], [880, 210], [400, 210]]


def box(cx: float, foot: float, w: float = 60, h: float = 150, score: float = 0.9) -> Player:
    return Player(bbox=(cx - w / 2, foot - h, w, h), score=score)


def test_tracking_keeps_ids_when_players_cross() -> None:
    tracker = PlayerTracker()
    near0, far0 = tracker.update([box(500, 600), box(700, 300)])
    assert near0.bbox[0] == 470 and far0.bbox[0] == 670
    # Both drift towards the middle; far ends up lower in the image than near for a moment.
    for t in range(1, 11):
        a = box(500 + 10 * t, 600 - 32 * t)
        b = box(700 - 10 * t, 300 + 32 * t)
        near, far = tracker.update([b, a])  # detector order shuffled
        assert near is a and far is b


def test_filters_people_outside_court() -> None:
    h = compute_homography(CORNERS)
    on_court = box(640, 600, w=80, h=200)
    umpire = box(100, 400, w=90, h=220)  # far outside the sideline, larger box
    far = box(640, 260)
    kept = filter_players([umpire, on_court, far], frame_height=720, homography=h)
    assert umpire not in kept and len(kept) == 2
    stands = box(640, 50)
    assert filter_players([stands, on_court], frame_height=720) == [on_court]


def test_hold_missing_player_for_n_frames() -> None:
    tracker = PlayerTracker(hold_frames=2, hold_decay=0.5)
    tracker.update([box(500, 600), box(700, 300)])
    near, far = tracker.update([box(505, 600)])
    assert far is not None and far.score == 0.45
    _, far = tracker.update([box(510, 600)])
    assert far is not None
    _, far = tracker.update([box(515, 600)])
    assert far is None


def test_smoothing_reduces_jitter() -> None:
    rng = np.random.default_rng(0)
    seq = [[(100 + rng.normal(0, 3), 200 + rng.normal(0, 3), 0.9)] * 17 for _ in range(40)]
    out = smooth_keypoints(seq, window=5)
    before = np.var([k[0][0] for k in seq])
    after = np.var([k[0][0] for k in out])
    assert after < before / 2
    assert all(len(k) == 17 for k in out)


def test_low_score_joints_not_smoothed_into_good_ones() -> None:
    good = [(100.0, 100.0, 0.9)] * 17
    bad = [(500.0, 500.0, 0.1)] * 17
    out = smooth_keypoints([good, bad, good], window=3, min_score=0.3)
    assert out[0][0][:2] == (100.0, 100.0)
    assert out[1][0] == (500.0, 500.0, 0.1)  # low-score joint left as is
    gap = smooth_keypoints([good, None, [(200.0, 200.0, 0.9)] * 17], window=3)
    assert gap[0][0][:2] == (100.0, 100.0) and gap[1] is None


def test_bbox_from_keypoints() -> None:
    kps = np.array([[10, 10], [30, 50], [20, 90]], float)
    assert bbox_from_keypoints(kps, np.array([0.9, 0.9, 0.9]), pad=0) == (10, 10, 20, 80)
    assert bbox_from_keypoints(kps, np.array([0.9, 0.1, 0.1])) is None
