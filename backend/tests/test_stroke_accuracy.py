"""Motion channels, forest v3 rows, test-time augmentation and the weighted ensemble (D41)."""

from __future__ import annotations

import numpy as np
import pytest

from shuttlesense.strokes.classify import average_probabilities, tta_windows
from shuttlesense.strokes.dataset import augment, warp_window
from shuttlesense.strokes.features import POSE_FEATURES, flip_window
from shuttlesense.strokes.motion import MOTION_POSE, MOTION_SHUTTLE, expand, expanded_features
from shuttlesense.strokes.rf import Forest, summary_features


def _window(t: int = 30) -> np.ndarray:
    """A pose drifting right at 0.01 per frame and a shuttle moving at (0.02, -0.01)."""
    x = np.zeros((t, 39), np.float32)
    frames = np.arange(t, dtype=np.float32)
    pose = np.tile(np.linspace(0.1, 0.5, POSE_FEATURES, dtype=np.float32), (t, 1))
    pose[:, 0::2] += 0.01 * frames[:, None]
    x[:, :POSE_FEATURES] = pose
    x[:, POSE_FEATURES] = 0.2 + 0.02 * frames
    x[:, POSE_FEATURES + 1] = 0.8 - 0.01 * frames
    x[:, POSE_FEATURES + 2] = 1.0
    x[1:, POSE_FEATURES + 3] = 0.02
    x[1:, POSE_FEATURES + 4] = -0.01
    return x


def test_expand_adds_velocities_and_keeps_the_window() -> None:
    x = _window()
    out = expand(x, 2)
    assert out.shape == (30, expanded_features(39, 2)) == (30, 39 + MOTION_POSE + MOTION_SHUTTLE)
    assert out[:, :39] == pytest.approx(x)
    vel = out[:, 39 : 39 + POSE_FEATURES]
    assert vel[:, 0::2] == pytest.approx(0.01, abs=1e-6)  # x of every joint
    assert vel[:, 1::2] == pytest.approx(0.0, abs=1e-6)
    speed = out[:, 39 + MOTION_POSE]
    assert speed == pytest.approx(np.hypot(0.02, 0.01), abs=1e-6)
    sin, cos = out[:, 39 + MOTION_POSE + 1], out[:, 39 + MOTION_POSE + 2]
    assert sin == pytest.approx(-0.01 / np.hypot(0.02, 0.01), abs=1e-5)
    assert cos == pytest.approx(0.02 / np.hypot(0.02, 0.01), abs=1e-5)
    assert out[:, -2:] == pytest.approx(0.0, abs=1e-6)  # constant velocity: no acceleration
    assert expand(x, 1) is x


def test_expand_never_differences_across_a_gap() -> None:
    x = _window()
    x[10:14] = 0.0  # player and shuttle gone
    out = expand(x[None], 2)[0]
    assert (out[10:14, 39:] == 0).all()
    # The frames next to the gap use the one-sided step, not a jump to zero.
    assert out[9, 39] == pytest.approx(0.01, abs=1e-6)
    assert out[14, 39] == pytest.approx(0.01, abs=1e-6)


def test_expand_pose_only_window() -> None:
    x = _window()[:, :POSE_FEATURES]
    assert expand(x, 2).shape == (30, expanded_features(POSE_FEATURES, 2))
    with pytest.raises(ValueError):
        expand(x, 9)


def test_warp_keeps_the_hit_frame_and_scales_the_step() -> None:
    x = _window()
    fast = warp_window(x, 1.5)
    assert fast[15, : POSE_FEATURES + 3] == pytest.approx(x[15, : POSE_FEATURES + 3], abs=1e-6)
    assert fast[16, POSE_FEATURES + 3] == pytest.approx(0.03, abs=1e-5)
    assert warp_window(x, 1.0) == pytest.approx(x, abs=1e-6)


def test_augment_with_time_warp_is_finite() -> None:
    rng = np.random.default_rng(0)
    out = augment(_window(), rng, True, time_warp=0.2, scale_jitter=0.1, shuttle_dropout=1.0)
    assert out.shape == (30, 39) and np.isfinite(out).all()


def test_summary_v3_extends_v2() -> None:
    x = np.stack([_window(), flip_window(_window())])
    v2, v3 = summary_features(x, 2), summary_features(x, 3)
    assert v3.shape[1] > v2.shape[1]
    assert v3[:, : v2.shape[1]] == pytest.approx(v2)
    assert np.isfinite(v3).all()
    assert np.isfinite(summary_features(np.zeros((2, 30, 39), np.float32), 3)).all()
    assert np.isfinite(summary_features(np.zeros((2, 30, 34), np.float32), 3)).all()


def test_forest_temperature_softens_probabilities() -> None:
    left = np.array([1, -1, -1], np.int32)
    right = np.array([2, -1, -1], np.int32)
    value = np.array([[0, 0], [0.9, 0.1], [0.2, 0.8]], np.float32)
    args = (left, right, np.zeros(3, np.int32), np.zeros(3, np.float32), value)
    rows = np.array([[-1.0], [1.0]], np.float32)
    sharp = Forest(*args, np.array([0], np.int32), {"classes": ["a", "b"]}).predict_proba(rows)
    soft = Forest(*args, np.array([0], np.int32), {"classes": ["a", "b"], "temperature": 2.0})
    p = soft.predict_proba(rows)
    assert sharp[0] == pytest.approx([0.9, 0.1])
    assert p[0, 0] < 0.9 and p[0].argmax() == 0 and p.sum(1) == pytest.approx(1.0)


def test_tta_views() -> None:
    x = np.stack([_window(), _window()])
    views = tta_windows(x, True, flip=True, shifts=[-1, 0, 1])
    assert len(views) == 4 and all(v.shape == x.shape for v in views)
    assert views[1][0] == pytest.approx(flip_window(x[0]))
    assert len(tta_windows(x, True, flip=False, shifts=[])) == 1


def test_weighted_and_geometric_ensemble() -> None:
    classes = ["a", "b"]
    sure = (np.array([[0.9, 0.1]]), ["a", "b"])
    unsure = (np.array([[0.4, 0.6]]), ["a", "b"])
    plain = average_probabilities([sure, unsure], classes)
    assert plain[0] == pytest.approx([0.65, 0.35])
    weighted = average_probabilities([sure, unsure], classes, [1.0, 3.0])
    assert weighted[0] == pytest.approx([0.525, 0.475])
    geo = average_probabilities([sure, unsure], classes, geometric=True)
    expected = np.sqrt([0.9 * 0.4, 0.1 * 0.6])
    assert geo[0] == pytest.approx(expected / expected.sum())
    # A model that does not know a class counts as ruling it out.
    partial = average_probabilities([sure, (np.array([[1.0]]), ["a"])], classes, geometric=True)
    assert partial[0, 0] > 0.99
