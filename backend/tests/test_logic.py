"""Pure-logic helpers that need no GPU or models."""

from __future__ import annotations

import csv

import numpy as np
import pytest

from shuttlesense.analytics import build_summary, speeds_kmh, write_exports
from shuttlesense.feedback import joint_angle
from shuttlesense.hits import direction_changes
from shuttlesense.pose import assign_sides
from shuttlesense.referee import game_winner
from shuttlesense.schema import ClipRecord, Hit, Player
from shuttlesense.strokes import SHUTTLESET_TO_CLASS, map_label
from shuttlesense.tracking import interpolate_gaps


def test_interpolate_fills_short_gap_only() -> None:
    xy = np.array([[0, 0], [0, 0], [0, 0], [3, 3], [0, 0], [0, 0], [0, 0], [0, 0], [8, 8]], float)
    vis = np.array([1, 0, 0, 1, 0, 0, 0, 0, 1])
    out_xy, out_vis = interpolate_gaps(xy, vis, max_gap=2)
    np.testing.assert_allclose(out_xy[1:3], [[1, 1], [2, 2]])
    assert out_vis.tolist() == [1, 1, 1, 1, 0, 0, 0, 0, 1]


def test_direction_change_detected_at_bounce() -> None:
    xy = np.array([[0, 0], [1, 0], [2, 0], [3, 0], [2, 0], [1, 0]], float)
    assert direction_changes(xy, min_angle_deg=60) == [3]


def test_assign_sides_by_feet_position() -> None:
    far = Player(bbox=(100, 50, 40, 100))
    near = Player(bbox=(100, 300, 60, 200))
    assert assign_sides([far, near]) == (near, far)
    assert assign_sides([]) == (None, None)


def test_joint_angle_right_angle() -> None:
    angle = joint_angle(np.array([0.0, 1.0]), np.array([0.0, 0.0]), np.array([1.0, 0.0]))
    assert angle == pytest.approx(90.0)


def test_speed_constant_motion() -> None:
    track = np.array([[0.0, i * 0.5] for i in range(10)])  # 0.5 m per frame at 30 fps
    kmh = speeds_kmh(track, fps=30, smooth=1)
    np.testing.assert_allclose(kmh, 0.5 * 30 * 3.6)


def test_label_mapping_covers_18_types() -> None:
    assert len(SHUTTLESET_TO_CLASS) == 18
    assert map_label(" Wrist Smash ") == "smash"
    assert map_label("drive") is None
    with pytest.raises(KeyError):
        map_label("tennis serve")


@pytest.mark.parametrize(
    ("near", "far", "winner"),
    [
        (21, 19, "near"),
        (20, 20, None),
        (21, 20, None),
        (22, 20, "near"),
        (29, 30, "far"),
        (5, 21, "far"),
    ],
)
def test_bwf_game_winner(near: int, far: int, winner: str | None) -> None:
    assert game_winner(near, far) == winner


def test_summary_and_exports(tmp_path) -> None:
    record = ClipRecord(
        clip_id="c",
        fps=30,
        width=1280,
        height=720,
        num_frames=100,
        hits=[
            Hit(id=0, frame=10, time_s=0.33, player="near", stroke="smash", speed_kmh=150.0),
            Hit(id=1, frame=40, time_s=1.33, player="far", stroke="lift", speed_kmh=60.0),
            Hit(id=2, frame=70, time_s=2.33, player="near", stroke="smash"),
        ],
    )
    record.summary = build_summary(record)
    assert record.summary.stroke_counts == {"smash": 2, "lift": 1}
    assert record.summary.per_player["near"].peak_speed_kmh == 150.0

    write_exports(record, tmp_path)
    rows = list(csv.DictReader((tmp_path / "hits.csv").open(encoding="utf-8")))
    assert [r["stroke"] for r in rows] == ["smash", "lift", "smash"]
    assert (tmp_path / "record.json").exists() and (tmp_path / "summary.json").exists()
