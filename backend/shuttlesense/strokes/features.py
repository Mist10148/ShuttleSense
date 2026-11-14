"""Feature windows around a hit, shared by training and inference (F6, T3.5).

Per frame: the hitter's 17 keypoints (x, y), centred on the bbox centre and divided by
the bbox height or diagonal (34 values), then the shuttle (x / width, y / height, visible,
dx, dy) (5 values) unless use_trajectory is False (pose-only ablation). Frames outside the
clip or with the player missing are zeros; the shuttle's visible flag tells the model it is
gone.

pose_norm: "bbox_height" is the original rule. "bbox_diag" divides by the box diagonal, as the
BST ShuttleSet features do (D29); the shipped weights were trained with it. A checkpoint
stores the rule it was trained with and inference follows it.
"""

from __future__ import annotations

import numpy as np

from shuttlesense.schema import NUM_KEYPOINTS, ClipRecord

POSE_FEATURES = NUM_KEYPOINTS * 2
SHUTTLE_FEATURES = 5
POSE_NORMS = ("bbox_height", "bbox_diag")

# COCO left/right joint pairs, swapped when a window is mirrored (augmentation).
FLIP_PAIRS = ((1, 2), (3, 4), (5, 6), (7, 8), (9, 10), (11, 12), (13, 14), (15, 16))


def num_features(use_trajectory: bool = True) -> int:
    return POSE_FEATURES + (SHUTTLE_FEATURES if use_trajectory else 0)


def pose_vector(
    keypoints: list[tuple[float, float, float]] | None,
    bbox: tuple[float, float, float, float] | None,
    pose_norm: str = "bbox_height",
) -> np.ndarray:
    """34 bbox-relative values; zeros when the player is missing."""
    if pose_norm not in POSE_NORMS:
        raise ValueError(f"unknown pose_norm {pose_norm!r}")
    out = np.zeros(POSE_FEATURES, dtype=np.float32)
    if not keypoints or bbox is None or bbox[3] <= 0:
        return out
    x, y, w, h = bbox
    cx, cy = x + w / 2, y + h / 2
    scale = h if pose_norm == "bbox_height" else float(np.hypot(w, h))
    kps = np.asarray(keypoints[:NUM_KEYPOINTS], dtype=np.float32)
    out[: 2 * len(kps)] = ((kps[:, :2] - [cx, cy]) / scale).reshape(-1)
    return out


def shuttle_features(xy: np.ndarray, visible: np.ndarray) -> np.ndarray:
    """[T, 5] (x, y, visible, dx, dy) from normalised positions [T, 2] and a visible mask [T].

    dx, dy are the step from the frame before, and 0 when that frame had no shuttle. Frames
    without a shuttle are all zeros. Shared by inference and the BST feature import.
    """
    xy = np.asarray(xy, dtype=np.float32)
    seen = np.asarray(visible, dtype=bool)
    out = np.zeros((len(xy), SHUTTLE_FEATURES), dtype=np.float32)
    out[seen, 0:2] = xy[seen]
    out[seen, 2] = 1.0
    if len(xy) > 1:
        step = seen[1:] & seen[:-1]
        out[1:, 3:5][step] = (xy[1:] - xy[:-1])[step]
    return out


def build_window(
    record: ClipRecord,
    hit_frame: int,
    player: str,  # a Players field: near / far, or a doubles partner (near_2 / far_2)
    window: int = 32,
    use_trajectory: bool = True,
    pose_norm: str = "bbox_height",
) -> np.ndarray:
    """[window, F] features for the frames centred on `hit_frame` (start = hit - window // 2)."""
    feats = np.zeros((window, num_features(use_trajectory)), dtype=np.float32)
    w = record.width or 1
    h = record.height or 1
    start = hit_frame - window // 2
    xy = np.zeros((window, 2), dtype=np.float32)
    seen = np.zeros(window, dtype=bool)
    for t in range(window):
        i = start + t
        if not 0 <= i < len(record.frames):
            continue
        frame = record.frames[i]
        p = getattr(frame.players, player)
        feats[t, :POSE_FEATURES] = pose_vector(
            p.keypoints if p else None, p.bbox if p else None, pose_norm
        )
        s = frame.shuttle
        if s is not None and s.visible and s.x is not None and s.y is not None:
            xy[t] = (s.x / w, s.y / h)
            seen[t] = True
    if use_trajectory:
        feats[:, POSE_FEATURES:] = shuttle_features(xy, seen)
    return feats


def flip_window(x: np.ndarray, use_trajectory: bool = True) -> np.ndarray:
    """Mirror a [T, F] window horizontally: negate x and swap left/right joints."""
    out = x.copy()
    pose = out[:, :POSE_FEATURES].reshape(len(out), NUM_KEYPOINTS, 2)
    pose[:, :, 0] *= -1
    for a, b in FLIP_PAIRS:
        pose[:, [a, b]] = pose[:, [b, a]]
    out[:, :POSE_FEATURES] = pose.reshape(len(out), -1)
    if use_trajectory and out.shape[1] > POSE_FEATURES:
        visible = out[:, POSE_FEATURES + 2] > 0
        out[visible, POSE_FEATURES] = 1.0 - out[visible, POSE_FEATURES]  # x / width
        out[:, POSE_FEATURES + 3] *= -1  # dx
    return out
