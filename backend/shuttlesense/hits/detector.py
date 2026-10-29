"""Rule-based hit detector (F5, FR-5).

A hit is a frame where the shuttle's direction changes sharply while it is within
`max_wrist_distance_px` of a player's wrist. Thresholds live in configs/pipeline.yaml.
"""

from __future__ import annotations

import numpy as np

from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext


def direction_changes(xy: np.ndarray, min_angle_deg: float) -> list[int]:
    """Indices where the trajectory turns by more than `min_angle_deg`.

    xy: (N, 2) positions of consecutive visible frames.
    """
    if len(xy) < 3:
        return []
    v = np.diff(xy, axis=0)
    a, b = v[:-1], v[1:]
    norms = np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1)
    with np.errstate(invalid="ignore", divide="ignore"):
        cos = np.einsum("ij,ij->i", a, b) / norms
    angles = np.degrees(np.arccos(np.clip(np.nan_to_num(cos, nan=1.0), -1.0, 1.0)))
    return [i + 1 for i in np.flatnonzero(angles > min_angle_deg)]


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill record.hits with (frame, time_s, player).

    TODO(T3.6): combine direction_changes() with distance to each player's wrists
    (keypoints 9 and 10), enforce min_frames_between_hits, assign the closest player.
    """
    ctx.progress(1.0)
    return record
