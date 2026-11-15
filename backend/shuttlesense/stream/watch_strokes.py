"""Conservative stroke-label evidence checks for watch sessions."""

from __future__ import annotations

import math

import numpy as np

from shuttlesense.strokes.features import POSE_FEATURES, build_window


def sufficient_evidence(
    record, hit, checkpoint: dict, threshold: float = 0.5, *, unobserved: set[int] | None = None
) -> bool:
    window = int(checkpoint.get("window_frames", 32))
    use_traj = bool(checkpoint.get("use_trajectory", True))
    window_fps = checkpoint.get("window_fps")
    step = record.fps / float(window_fps) if window_fps and record.fps else 1.0
    if abs(step - 1.0) < 0.02:
        step = 1.0
    first = hit.frame - (window // 2) * step
    last = hit.frame + (window - 1 - window // 2) * step
    if first < 0 or math.ceil(last) >= len(record.frames):
        return False
    if hit.confidence is None or not math.isfinite(hit.confidence) or hit.confidence < threshold:
        return False
    feats = build_window(
        record,
        hit.frame,
        hit.player_attr,
        window,
        use_traj,
        checkpoint.get("pose_norm", "bbox_height"),
        window_fps,
    )
    missing = unobserved or set()
    observed = np.array(
        [
            math.floor(position) not in missing and math.ceil(position) not in missing
            for position in (hit.frame + (np.arange(window) - window // 2) * step)
        ]
    )
    if np.count_nonzero(np.any(feats[:, :POSE_FEATURES] != 0, axis=1) & observed) < math.ceil(
        window * 0.5
    ):
        return False
    return not (
        use_traj
        and np.count_nonzero((feats[:, POSE_FEATURES + 2] > 0) & observed) < math.ceil(window * 0.5)
    )


def guard_hits(
    record,
    checkpoint: dict | None,
    threshold: float = 0.5,
    *,
    doubles=False,
    unobserved: set[int] | None = None,
) -> None:
    for hit in record.hits:
        if (
            checkpoint is None
            or (doubles and hit.hitter is None)
            or not sufficient_evidence(record, hit, checkpoint, threshold, unobserved=unobserved)
        ):
            hit.stroke = None
            hit.confidence = None
            hit.class_probs = None
            hit.feedback = []
