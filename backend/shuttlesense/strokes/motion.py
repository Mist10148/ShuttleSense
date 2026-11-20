"""Motion channels derived from a stroke window (feature version 2, D41).

The feature windows (strokes/features.py) hold positions only: the pose, and the shuttle
with one step (dx, dy). Velocities are what tell a drop from a smash and a lift from a net
shot, and a network has to learn to difference frames to see them. Version 2 adds them as
channels computed from the same window, so the stored training features, the live and
Watch windows and the BST import stay as they are:

- the pose velocity of each joint (34 values), a central difference over frames that hold
  the player, 0 where a neighbour frame is missing;
- the speed of each wrist (2);
- the shuttle speed, the sine and cosine of its direction of travel (3) and its
  acceleration (2), 0 without three frames in a row that hold the shuttle.

`expand` runs after augmentation in training and before the model at inference; a
checkpoint stores `feature_version` and old checkpoints (version 1) get the window as is.
"""

from __future__ import annotations

import numpy as np

from shuttlesense.strokes.features import POSE_FEATURES

FEATURE_VERSIONS = (1, 2)
L_WRI, R_WRI = 9, 10
MOTION_POSE = POSE_FEATURES + 2  # joint velocities and the two wrist speeds
MOTION_SHUTTLE = 5  # speed, direction (sin, cos), acceleration (ax, ay)


def expanded_features(base: int, version: int) -> int:
    """Width of a window with `base` columns after `expand(..., version)`."""
    if version == 1:
        return base
    return base + MOTION_POSE + (MOTION_SHUTTLE if base > POSE_FEATURES else 0)


def _central_diff(values: np.ndarray, valid: np.ndarray) -> np.ndarray:
    """Per-frame velocity of values [N, T, D]: central difference where both neighbours
    are valid, one-sided at an edge of a valid run, 0 for a frame on its own."""
    n, t, d = values.shape
    out = np.zeros_like(values)
    if t < 2:
        return out
    prev_ok = np.zeros((n, t), bool)
    next_ok = np.zeros((n, t), bool)
    prev_ok[:, 1:] = valid[:, 1:] & valid[:, :-1]
    next_ok[:, :-1] = valid[:, :-1] & valid[:, 1:]
    fwd = np.zeros_like(values)
    bwd = np.zeros_like(values)
    fwd[:, :-1] = values[:, 1:] - values[:, :-1]
    bwd[:, 1:] = values[:, 1:] - values[:, :-1]
    both = prev_ok & next_ok
    out[both] = (fwd[both] + bwd[both]) / 2
    only_next = next_ok & ~prev_ok
    only_prev = prev_ok & ~next_ok
    out[only_next] = fwd[only_next]
    out[only_prev] = bwd[only_prev]
    return out


def expand(x: np.ndarray, version: int = 2) -> np.ndarray:
    """Append the motion channels to windows x [N, T, F] or one window [T, F]."""
    if version == 1:
        return x
    if version not in FEATURE_VERSIONS:
        raise ValueError(f"unknown stroke feature version {version}")
    single = x.ndim == 2
    w = np.asarray(x[None] if single else x, dtype=np.float32)
    n, t, f = w.shape
    pose = w[:, :, :POSE_FEATURES]
    present = np.any(pose != 0, axis=-1)
    vel = _central_diff(pose, present)
    joints = vel.reshape(n, t, -1, 2)
    wrists = np.linalg.norm(joints[:, :, [L_WRI, R_WRI]], axis=-1)
    parts = [w, vel, wrists]
    if f > POSE_FEATURES:
        sh = w[:, :, POSE_FEATURES : POSE_FEATURES + 2]
        seen = w[:, :, POSE_FEATURES + 2] > 0.5
        v = _central_diff(sh, seen)
        speed = np.linalg.norm(v, axis=-1, keepdims=True)
        moving = speed[..., 0] > 1e-6
        direction = np.zeros((n, t, 2), np.float32)
        direction[moving] = v[moving][:, [1, 0]] / speed[moving]  # (sin, cos) of travel
        accel = _central_diff(v, seen & moving)
        parts += [speed, direction, accel]
    out = np.concatenate(parts, axis=-1).astype(np.float32)
    return out[0] if single else out
