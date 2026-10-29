from __future__ import annotations

import numpy as np

from shuttlesense.fake import load_golden
from shuttlesense.strokes.features import (
    POSE_FEATURES,
    build_window,
    flip_window,
    num_features,
    pose_vector,
)


def test_window_shape() -> None:
    record = load_golden()
    x = build_window(record, 25, "far", window=32)
    assert x.shape == (32, num_features(True)) == (32, 39)
    assert x.dtype == np.float32


def test_pose_only_drops_shuttle_columns() -> None:
    record = load_golden()
    full = build_window(record, 25, "near", window=16)
    pose = build_window(record, 25, "near", window=16, use_trajectory=False)
    assert pose.shape == (16, POSE_FEATURES)
    np.testing.assert_array_equal(full[:, :POSE_FEATURES], pose)


def test_missing_frames_are_zero_with_visible_flag() -> None:
    record = load_golden()
    x = build_window(record, 2, "near", window=16)  # starts before frame 0
    assert not x[:6].any()
    assert x[6, POSE_FEATURES + 2] == 1.0
    gap = build_window(record, 33, "near", window=4)  # frames 31-34; 31 and 32 have no shuttle
    assert gap[0, POSE_FEATURES + 2] == 0.0 and gap[1, POSE_FEATURES + 2] == 0.0
    assert not gap[0, POSE_FEATURES:].any() and gap[0, :POSE_FEATURES].any()
    assert gap[2, POSE_FEATURES + 2] == 1.0 and gap[2, POSE_FEATURES + 3] == 0.0  # no dx


def test_normalization_is_bbox_relative() -> None:
    kps = [(150.0, 100.0, 0.9)] * 17
    v = pose_vector(kps, (100.0, 50.0, 100.0, 200.0))  # centre (150, 150), height 200
    assert v[0] == 0.0 and v[1] == -0.25
    moved = pose_vector([(250.0, 300.0, 0.9)] * 17, (200.0, 250.0, 100.0, 200.0))
    np.testing.assert_allclose(v, moved)
    assert not pose_vector(None, None).any()


def test_flip_swaps_left_right_joints() -> None:
    x = np.zeros((2, 39), np.float32)
    x[:, 18] = 0.3  # left wrist (9) x
    x[:, 20] = -0.1  # right wrist (10) x
    x[:, POSE_FEATURES : POSE_FEATURES + 3] = (0.2, 0.5, 1.0)
    f = flip_window(x)
    assert f[0, 18] == np.float32(0.1) and f[0, 20] == np.float32(-0.3)
    assert f[0, POSE_FEATURES] == np.float32(0.8)
    np.testing.assert_allclose(flip_window(f), x)
