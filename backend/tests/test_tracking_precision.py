"""Tracking precision (D43): sub-pixel heatmap peaks, depth-aware outlier thresholds, flight
fitting, hit timing and the court line fit, on synthetic data with known ground truth."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import cv2
import numpy as np
import pytest

from shuttlesense.hits import detect_hits
from shuttlesense.tracking.postprocess import (
    heatmap_peak,
    heatmap_to_xy,
    offline_tracking,
    rectify,
    remove_outliers,
)
from shuttlesense.tracking.trajectory import refine_track, smooth_points, turn_time

# The behaviour before D43: no depth scaling, no flight fitting.
OLD = {"depth_aware": False, "trajectory": False}


@pytest.fixture(autouse=True)
def _offline():
    """These tests cover the upload path, where the tracking stage runs rectify."""
    with offline_tracking():
        yield


def test_top_edge_lift_stays_missing_until_reentry() -> None:
    xy = np.array([[40, 26], [45, 12], [0, 0], [0, 0], [60, 11], [65, 25]])
    _, visible, source = rectify(
        xy, np.array([1, 1, 0, 0, 1, 1]), frame_height=720, max_gap=8, outlier_px=80
    )
    assert visible.tolist() == [1, 1, 0, 0, 1, 1]
    assert source[2:4] == ["", ""]


def test_live_windows_skip_the_flight_fitting_by_default() -> None:
    t = np.arange(40, dtype=float)
    xy = np.stack([100 + 5 * t, 300 - 8 * t + 0.2 * t**2], axis=1)
    xy[:, 1] += np.random.default_rng(0).normal(0, 2, 40)
    vis = np.ones(40, dtype=int)
    with offline_tracking():
        offline, _, _ = rectify(xy, vis, max_gap=8, outlier_px=80)
    from shuttlesense.tracking import postprocess

    reset = postprocess._OFFLINE.set(False)
    try:
        live, _, _ = rectify(xy, vis, max_gap=8, outlier_px=80)
        forced, _, _ = rectify(
            xy, vis, max_gap=8, outlier_px=80, settings={"trajectory_live": True}
        )
    finally:
        postprocess._OFFLINE.reset(reset)
    assert np.allclose(live, xy)  # outlier removal only: a clean flight is left as is
    assert not np.allclose(offline, xy)  # smoothed on uploads
    assert np.allclose(forced, offline)


def gaussian_heatmap(cx: float, cy: float, sigma: float = 2.5, size=(288, 512)) -> np.ndarray:
    ys, xs = np.indices(size, dtype=float)
    return np.exp(-((xs - cx) ** 2 + (ys - cy) ** 2) / (2 * sigma**2))


# Heatmap peak ----------------------------------------------------------------------------


def test_sub_pixel_peak_on_gaussian_heatmaps() -> None:
    rng = np.random.default_rng(0)
    errors_new, errors_old = [], []
    for _ in range(50):
        cx, cy = rng.uniform(20, 490), rng.uniform(20, 260)
        heat = gaussian_heatmap(cx, cy)
        x, y, vis = heatmap_to_xy(heat)
        assert vis == 1
        errors_new.append(np.hypot(x - cx, y - cy))
        # The old rule: the plain centroid of the thresholded blob.
        mask = (heat >= 0.5).astype(np.uint8)
        _, _, _, centroids = cv2.connectedComponentsWithStats(mask, connectivity=8)
        errors_old.append(np.hypot(*(centroids[1] - (cx, cy))))
    assert max(errors_new) < 0.05
    assert np.mean(errors_new) < np.mean(errors_old) / 3


def test_flat_top_falls_back_to_the_weighted_centroid() -> None:
    heat = np.zeros((72, 128))
    heat[40:46, 60:66] = 0.8  # saturated, no single peak
    assert heatmap_to_xy(heat) == (62.5, 42.5, 1)
    heat[42, 63] = 0.9  # one brighter pixel: a strict peak, symmetric, so located on it
    assert heatmap_to_xy(heat) == (63.0, 42.0, 1)


def test_blob_choice_scores_peak_area_and_prediction() -> None:
    heat = gaussian_heatmap(100, 100, sigma=3.0) + gaussian_heatmap(300, 150, sigma=2.0)
    assert heatmap_to_xy(heat)[0] == pytest.approx(100, abs=0.1)  # bigger blob wins
    # The track says the shuttle should be near (300, 150): the smaller blob is chosen.
    x, y, _ = heatmap_to_xy(heat, predicted=(295.0, 148.0))
    assert (x, y) == pytest.approx((300, 150), abs=0.1)
    peak = heatmap_peak(heat)
    assert peak.visible and peak.confidence == pytest.approx(1.0, abs=1e-3) and peak.area > 0
    assert heatmap_peak(np.zeros((8, 8))).confidence == 0.0


# Depth-aware thresholds -----------------------------------------------------------------


def test_outlier_distance_follows_the_image_row() -> None:
    def isolated_jump(y: float, jump: float) -> int:
        xy = np.array([[100, y], [102, y], [104, y], [0, 0], [0, 0], [104 + jump, y]], float)
        visible = np.array([1, 1, 1, 0, 0, 1])
        return int(remove_outliers(xy, visible, 80, frame_height=720)[5])

    # A 70 px jump is plausible near the camera (bottom rows) but not at the far baseline.
    assert isolated_jump(650.0, 70.0) == 1
    assert isolated_jump(40.0, 70.0) == 0
    xy = np.array([[100, 40], [102, 40], [104, 40], [0, 0], [0, 0], [174, 40]], float)
    old = remove_outliers(xy, np.array([1, 1, 1, 0, 0, 1]), 80, depth_aware=False)
    assert old[5] == 1  # without depth scaling the far jump stood


# Flight fitting --------------------------------------------------------------------------


def synthetic_rally(rng: np.random.Generator, flights: int = 6, frames: int = 24) -> np.ndarray:
    """Parabolic flights between alternate ends of the image, hit to hit."""
    parts, x, y = [], 300.0, 600.0
    for k in range(flights):
        tx, ty = rng.uniform(250, 1000), 200.0 if k % 2 == 0 else 600.0
        arc = rng.uniform(80, 200)
        t = np.arange(1, frames + 1) / frames
        parts.append(np.stack([x + (tx - x) * t, y + (ty - y) * t - 4 * arc * t * (1 - t)], 1))
        x, y = tx, ty
    return np.concatenate(parts)


def corrupt(rng: np.random.Generator, truth: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Detector noise, dropouts, one long gap, false bursts and small outliers."""
    n = len(truth)
    xy = truth + rng.normal(0, 2.0, truth.shape)
    vis = np.ones(n, dtype=int)
    for _ in range(6):
        s = int(rng.integers(5, n - 20))
        vis[s : s + int(rng.integers(1, 6))] = 0
    s = int(rng.integers(20, n - 30))
    vis[s : s + 12] = 0
    for _ in range(3):
        s, length = int(rng.integers(5, n - 5)), int(rng.integers(1, 3))
        xy[s : s + length] = rng.uniform(0, 1280), rng.uniform(0, 720)
        vis[s : s + length] = 1
    for _ in range(4):
        xy[int(rng.integers(5, n - 5))] += rng.normal(0, 25, 2)
    return xy, vis


def rmse(xy: np.ndarray, truth: np.ndarray, mask: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.sum((xy[mask] - truth[mask]) ** 2, axis=1))))


def test_rectify_is_closer_to_ground_truth_than_before() -> None:
    rng = np.random.default_rng(1)
    old_err, new_err, old_vis, new_vis = [], [], [], []
    for _ in range(20):
        truth = synthetic_rally(rng)
        xy, vis = corrupt(rng, truth)
        o_xy, o_vis, _ = rectify(xy, vis, max_gap=8, outlier_px=80, settings=OLD)
        n_xy, n_vis, _ = rectify(xy, vis, max_gap=8, outlier_px=80)
        both = (o_vis > 0) & (n_vis > 0)
        old_err.append(rmse(o_xy, truth, both))
        new_err.append(rmse(n_xy, truth, both))
        old_vis.append(o_vis.mean())
        new_vis.append(n_vis.mean())
    # Measured when written: about 40 px before, 7 px after (seed 1), at the same coverage.
    assert np.mean(new_err) < 0.4 * np.mean(old_err)
    assert np.mean(new_vis) >= np.mean(old_vis) - 0.01


def test_smoothing_reduces_noise_on_a_clean_flight() -> None:
    rng = np.random.default_rng(2)
    t = np.arange(40, dtype=float)
    truth = np.stack([200 + 15 * t, 600 - 30 * t + 0.6 * t**2], axis=1)
    xy = truth + rng.normal(0, 2.0, truth.shape)
    out, vis, _ = rectify(xy, np.ones(40, dtype=int), max_gap=8, outlier_px=80)
    assert vis.all()
    assert rmse(out, truth, vis > 0) < 0.7 * rmse(xy, truth, vis > 0)


def test_long_gap_inside_one_flight_is_filled_from_the_fit() -> None:
    t = np.arange(50, dtype=float)
    truth = np.stack([200 + 12 * t, 600 - 25 * t + 0.5 * t**2], axis=1)
    visible = np.ones(50, dtype=int)
    visible[20:35] = 0  # 15 frames: beyond max_gap_frames (8)
    xy = truth * visible[:, None]
    old_xy, old_vis, _ = rectify(xy, visible, max_gap=8, outlier_px=80, settings=OLD)
    assert not old_vis[20:35].any()
    out, vis, source = rectify(xy, visible, max_gap=8, outlier_px=80)
    assert vis[20:35].all() and set(source[20:35]) == {"interp"}
    assert np.abs(out[20:35] - truth[20:35]).max() < 1.0


def test_gap_hiding_a_hit_is_not_filled_from_one_fit() -> None:
    t = np.arange(30, dtype=float)
    out_flight = np.stack([200 + 12 * t, 600 - 20 * t + 0.4 * t**2], axis=1)
    back = out_flight[-1] + np.stack([-10 * t, 15 * t], axis=1)  # struck back
    truth = np.concatenate([out_flight, back])
    visible = np.ones(60, dtype=int)
    visible[24:36] = 0  # the hit at frame 30 is in the gap
    r = refine_track(truth * visible[:, None], visible)
    assert not r.filled[24:36].any()


def test_smoothing_never_crosses_a_hit() -> None:
    rng = np.random.default_rng(3)
    t = np.arange(20, dtype=float)
    a = np.stack([300 + 14 * t, 500 - 12 * t], axis=1)
    b = a[-1] + np.stack([-16 * (t + 1), 9 * (t + 1)], axis=1)
    truth = np.concatenate([a, b])  # a sharp turn at frame 19
    xy = truth + rng.normal(0, 1.0, truth.shape)
    frames = np.arange(40)
    out, alive, turn = smooth_points(frames, xy)
    assert alive.all() and turn[18:21].any()
    assert np.allclose(out[19], xy[19])  # the corner is kept as detected
    # A plain moving average would cut the corner by several pixels.
    window = xy[16:23].mean(axis=0)
    assert np.linalg.norm(window - truth[19]) > 5
    assert np.linalg.norm(out[17] - truth[17]) < 3 and np.linalg.norm(out[21] - truth[21]) < 3


def test_landing_corner_is_kept() -> None:
    t = np.arange(15, dtype=float)
    fall = np.stack([400 + 20 * t, 200 + 30 * t], axis=1)
    rest = np.repeat(fall[-1:], 15, axis=0)
    xy = np.concatenate([fall, rest])
    out, vis, _ = rectify(xy, np.ones(30, dtype=int), max_gap=8, outlier_px=80)
    assert vis.all() and np.abs(out - xy).max() < 1.0


# Hit timing --------------------------------------------------------------------------------


def test_turn_time_is_where_the_two_flights_meet() -> None:
    t_hit = 10.4  # between frames
    frames = np.arange(21, dtype=float)
    before = np.stack([100 + 20 * (frames - t_hit), 300 + 0 * frames], axis=1)
    after = np.stack([100 + 5 * (frames - t_hit), 300 - 18 * (frames - t_hit)], axis=1)
    pts = np.where((frames < t_hit)[:, None], before, after)
    assert turn_time(frames, pts, 10) == pytest.approx(t_hit, abs=0.06)


def test_hit_count_is_stable_on_noisy_synthetic_rallies() -> None:
    from shuttlesense.hits.detector import wrist_arrays
    from shuttlesense.stream.synthetic import synthetic_record
    from shuttlesense.tracking import track_arrays

    record, truth = synthetic_record()
    xy, visible = track_arrays(record)
    xy = np.nan_to_num(xy)
    near, far = wrist_arrays(record, "near"), wrist_arrays(record, "far")
    cfg = {"min_angle_deg": 60, "min_flip_px": 2.0, "max_wrist_distance_px": 120,
           "min_frames_between_hits": 8, "rally_break_frames": 30}  # fmt: skip
    old_cfg = {**cfg, "smooth_track": False, "refine_hit_frame": False}
    expected = [(f, s) for f, s, _ in truth["hits"]]

    def matches(hits: list) -> bool:
        return len(hits) == len(expected) and all(
            abs(a[0] - b[0]) <= 1 and a[1] == b[1] for a, b in zip(hits, expected, strict=True)
        )

    rng = np.random.default_rng(4)
    old_ok = new_ok = 0
    for _ in range(8):
        noisy = xy + rng.normal(0, 1.5, xy.shape) * (visible[:, None] > 0)
        old_xy, old_vis, _ = rectify(noisy, visible, max_gap=8, outlier_px=80, settings=OLD)
        old_ok += matches(detect_hits(old_xy, old_vis, near, far, old_cfg))
        new_xy, new_vis, _ = rectify(noisy, visible, max_gap=8, outlier_px=80)
        new_ok += matches(detect_hits(new_xy, new_vis, near, far, cfg))
    # Every planned hit within a frame and no extra one, in nearly every trial (one trial
    # has a noise flip next to the far wrist that the old code also takes for a hit).
    assert new_ok >= max(old_ok, 7)


# Court line fit ------------------------------------------------------------------------------


def test_least_squares_court_fit_is_sub_pixel() -> None:
    from shuttlesense.court.refine import refine_corners

    true = np.float32([[260.4, 620.3], [1020.7, 619.6], [810.25, 180.6], [469.6, 180.3]])
    image = np.full((720, 1280, 3), (40, 100, 40), np.uint8)
    unit = np.float32([[0, 0], [1, 0], [1, 1], [0, 1]])
    transform = cv2.getPerspectiveTransform(unit, true)
    s = 1.98 / 13.40
    segments = [((0, 0), (1, 0)), ((1, 0), (1, 1)), ((1, 1), (0, 1)), ((0, 1), (0, 0)),
                ((0, 0.5 - s), (1, 0.5 - s)), ((0, 0.5 + s), (1, 0.5 + s)),
                ((0.5, 0), (0.5, 0.5 - s)), ((0.5, 0.5 + s), (0.5, 1))]  # fmt: skip
    for a, b in segments:
        p = cv2.perspectiveTransform(np.float32([[a, b]]), transform)[0] * 16
        cv2.line(image, tuple(map(int, np.rint(p[0]))), tuple(map(int, np.rint(p[1]))),
                 (245, 245, 245), 3, cv2.LINE_AA, shift=4)  # fmt: skip
    tapped = true + np.float32([[5, -4], [-6, 3], [4, 5], [-3, -5]])
    grid, _ = refine_corners(image, tapped, lsq=False)
    fitted, report = refine_corners(image, tapped)
    assert report["least_squares"] and report["reprojection_px"] < 0.3
    assert report["reprojection_px"] <= report["reprojection_px_before"]
    assert np.abs(np.asarray(fitted) - true).max() < 0.35
    assert np.abs(np.asarray(fitted) - true).max() < np.abs(np.asarray(grid) - true).max()


# Smoothness report ------------------------------------------------------------------------


def test_smoothness_script_reports_jitter(tmp_path: Path) -> None:
    from shuttlesense.stream.synthetic import synthetic_record

    path = Path(__file__).resolve().parent.parent / "scripts" / "eval_track_smoothness.py"
    spec = importlib.util.spec_from_file_location("eval_track_smoothness", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    record, _ = synthetic_record()
    rng = np.random.default_rng(5)
    for f in record.frames:
        if f.shuttle and f.shuttle.visible:
            f.shuttle.x += float(rng.normal(0, 2.0))
            f.shuttle.y += float(rng.normal(0, 2.0))
    (tmp_path / "record.json").write_text(record.model_dump_json(), encoding="utf-8")
    result = module.evaluate(record, rerun=True)
    assert result["record"]["visible_ratio"] > 0.5
    assert result["rectified"]["flight_jitter_px2"] < result["record"]["flight_jitter_px2"]
    assert module.main([str(tmp_path / "record.json"), "--json"]) == 0


def test_a_shuttle_at_rest_is_never_a_turn_after_smoothing() -> None:
    from shuttlesense.hits.detector import direction_changes, smoothed_run

    t = np.arange(12, dtype=float)
    fall = np.stack([300 + 6 * t, 100 + 9 * t], axis=1)
    rest = np.repeat(fall[-1:] + [0.0, 0.004], 14, axis=0)  # lying still after landing
    pts = np.concatenate([fall, rest])
    smooth = smoothed_run(np.arange(len(pts)), pts, {"min_angle_deg": 60})
    assert all(i <= 13 for i in direction_changes(smooth, 60))
