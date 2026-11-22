"""Court heatmap export and gap-aware player positions (D44)."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from shuttlesense.analytics.export import write_exports
from shuttlesense.analytics.heatmap import (
    CELL_M,
    build_heatmap,
    density,
    grid_axes,
    sigma_at,
)
from shuttlesense.analytics.positions import (
    clamped_mask,
    foot_source,
    player_point,
    smooth_nan,
)
from shuttlesense.court import compute_homography
from shuttlesense.schema import ClipRecord, Court, CourtPositions, Frame, Landing, Player, Rally

SIZE = (5.18, 13.40)


def record_with(positions: list[tuple[float, float] | None], fps: float = 30.0, **kw) -> ClipRecord:
    corners = [[212.0, 650.0], [1068.0, 650.0], [880.0, 210.0], [400.0, 210.0]]
    frames = [
        Frame(frame=i, court_positions=CourtPositions(near=p)) for i, p in enumerate(positions)
    ]
    return ClipRecord(
        clip_id="h", fps=fps, width=1280, height=720, num_frames=len(frames), frames=frames,
        court=Court(corners_px=corners, homography=compute_homography(corners).tolist()),
        **kw,
    )  # fmt: skip


def test_mass_is_time_in_seconds() -> None:
    rng = np.random.default_rng(0)
    pts = [(float(x), float(y)) for x, y in rng.uniform([0, 0], [5, 6], (90, 2))]
    heat = build_heatmap(record_with(pts, fps=30.0))
    near = heat["players"]["near"]
    assert near["seconds"] == pytest.approx(3.0)
    assert np.sum(near["grid"]) == pytest.approx(3.0, rel=1e-3)
    assert np.sum(heat["players"]["far"]["grid"]) == 0.0
    assert heat["cell_m"] == CELL_M and len(near["grid"]) == heat["rows"]


def test_peak_is_at_a_stationary_player() -> None:
    heat = build_heatmap(record_with([(2.1, 3.4)] * 60))
    px, py = heat["players"]["near"]["peak_m"]
    assert abs(px - 2.1) <= CELL_M / 2 and abs(py - 3.4) <= CELL_M / 2


def test_sigma_grows_away_from_the_camera() -> None:
    assert sigma_at(np.array([0.0]), 13.4)[0] < sigma_at(np.array([13.4]), 13.4)[0]
    xs, ys = grid_axes(SIZE)
    near = density(np.array([[2.6, 1.0]]), np.ones(1), sigma_at(np.array([1.0]), 13.4), xs, ys)
    far = density(np.array([[2.6, 12.4]]), np.ones(1), sigma_at(np.array([12.4]), 13.4), xs, ys)
    assert near.max() > far.max()  # the same mass spread wider far away


def test_only_rally_frames_and_unclamped_positions_count() -> None:
    pts = [(1.0, 1.0)] * 30 + [(2.0, 2.0)] * 30 + [(-2.0, 3.0)] * 30  # last: at the clamp edge
    landing = Landing(x_m=2.0, y_m=10.0, in_court=True, confidence=0.9)
    rallies = [Rally(index=0, start_frame=30, end_frame=89, landing=landing)]
    heat = build_heatmap(record_with(pts, rallies=rallies))
    assert heat["players"]["near"]["seconds"] == pytest.approx(1.0)
    px, py = heat["players"]["near"]["peak_m"]
    assert (abs(px - 2.0), abs(py - 2.0)) <= (CELL_M / 2, CELL_M / 2)
    assert heat["landings"]["count"] == 1
    assert np.sum(heat["landings"]["grid"]) == pytest.approx(1.0, rel=1e-3)


def test_heatmap_json_is_written_next_to_summary(tmp_path: Path) -> None:
    write_exports(record_with([(2.0, 2.0)] * 10), tmp_path)
    data = json.loads((tmp_path / "heatmap.json").read_text(encoding="utf-8"))
    assert data["players"]["near"]["seconds"] == pytest.approx(10 / 30, abs=1e-3)
    record = record_with([(2.0, 2.0)] * 10)
    record.court = None
    write_exports(record, tmp_path)
    assert not (tmp_path / "heatmap.json").exists()


# Positions -----------------------------------------------------------------------------------


def test_smoothing_never_averages_across_a_gap() -> None:
    values = np.array([[0.0, 0.0]] * 5 + [[np.nan, np.nan]] + [[3.0, 0.0]] * 5)
    out = smooth_nan(values, 5)
    assert np.isnan(out[5]).all()
    assert np.allclose(out[:5], 0.0) and np.allclose(out[6:], [3.0, 0.0])


def test_median_drops_a_one_frame_glitch_and_speed_is_clamped() -> None:
    values = np.array([[1.0, 1.0]] * 10)
    values[5] = [4.0, 1.0]  # a pose glitch 3 m away
    assert np.allclose(smooth_nan(values, 5), 1.0)
    run = np.array([[0.0, 0.0], [0.0, 0.0], [2.0, 0.0], [2.0, 0.0]])  # 2 m in a frame
    out = smooth_nan(run, 1, fps=30.0)
    assert np.abs(np.diff(out[:, 0])).max() <= 8.0 / 30.0 + 1e-9


def test_lifted_foot_uses_the_planted_ankle() -> None:
    kps = [(0.0, 0.0, 0.9)] * 17
    kps[15] = (100.0, 480.0, 0.9)  # lifted: 40 px = 17% of the box above the other
    kps[16] = (140.0, 520.0, 0.9)
    p = Player(bbox=(80, 300, 80, 240), keypoints=kps)
    assert foot_source(p) == "lower_ankle"
    assert player_point(p, ankle_floor_ratio=0.0) == (140.0, 520.0)
    assert foot_source(Player(bbox=(80, 300, 80, 240))) == "box"


def test_clamped_points_are_flagged() -> None:
    pts = np.array([[-2.0, 3.0], [1.0, 1.0], [np.nan, np.nan], [7.18, 4.0], [1.0, 15.4]])
    assert clamped_mask(pts, SIZE, 2.0).tolist() == [True, False, False, True, True]
