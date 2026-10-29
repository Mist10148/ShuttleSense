"""Rule-based hit detector (F5, FR-5).

A hit is a frame where the shuttle's direction changes sharply while it is within
`max_wrist_distance_px` of a player's wrist. Thresholds live in configs/pipeline.yaml.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from shuttlesense.schema import ClipRecord, Hit, PlayerSide
from shuttlesense.stage import StageContext

LEFT_WRIST, RIGHT_WRIST = 9, 10
MIN_KEYPOINT_SCORE = 0.3


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


def vertical_flips(xy: np.ndarray) -> list[int]:
    """Indices where the shuttle stops moving down the image and starts moving up."""
    if len(xy) < 3:
        return []
    vy = np.diff(xy[:, 1])
    return [i + 1 for i in range(len(vy) - 1) if vy[i] > 0 and vy[i + 1] < 0]


def _wrist_distance(point: np.ndarray, wrists: np.ndarray | None) -> float:
    """Closest confident wrist to `point`; wrists is (2, 3) [x, y, score] or None."""
    if wrists is None:
        return float("inf")
    good = wrists[wrists[:, 2] >= MIN_KEYPOINT_SCORE]
    if len(good) == 0:
        return float("inf")
    return float(np.min(np.linalg.norm(good[:, :2] - point, axis=1)))


def detect_hits(
    xy: np.ndarray,
    visible: np.ndarray,
    wrists_near: list[np.ndarray | None],
    wrists_far: list[np.ndarray | None],
    cfg: dict[str, Any],
) -> list[tuple[int, PlayerSide]]:
    """Hits as (frame, player), in frame order.

    Candidates are sharp direction changes and down-to-up flips of the visible trajectory.
    A candidate counts if a confident wrist is within max_wrist_distance_px (scaled by
    cfg["scale"], the frame height / 720); the closest player is the hitter. Within
    min_frames_between_hits only the closest-wrist candidate survives, and consecutive hits
    by the same player (impossible in singles) keep only the closer one.
    """
    idx = np.flatnonzero(np.asarray(visible) > 0)
    if len(idx) < 3:
        return []
    pts = np.asarray(xy, dtype=float)[idx]
    cand = set(direction_changes(pts, cfg.get("min_angle_deg", 60))) | set(vertical_flips(pts))
    max_dist = cfg.get("max_wrist_distance_px", 120) * cfg.get("scale", 1.0)

    scored: list[tuple[float, int, PlayerSide]] = []
    for c in sorted(cand):
        frame = int(idx[c])
        d_near = _wrist_distance(pts[c], wrists_near[frame])
        d_far = _wrist_distance(pts[c], wrists_far[frame])
        d, side = (d_near, "near") if d_near <= d_far else (d_far, "far")
        if d <= max_dist:
            scored.append((d, frame, side))

    min_gap = cfg.get("min_frames_between_hits", 8)
    kept: list[tuple[float, int, PlayerSide]] = []
    for d, frame, side in sorted(scored):
        if all(abs(frame - k[1]) >= min_gap for k in kept):
            kept.append((d, frame, side))
    kept.sort(key=lambda k: k[1])

    alternating: list[tuple[float, int, PlayerSide]] = []
    for hit in kept:
        if alternating and alternating[-1][2] == hit[2]:
            if hit[0] < alternating[-1][0]:
                alternating[-1] = hit
            continue
        alternating.append(hit)
    return [(frame, side) for _d, frame, side in alternating]


def wrist_arrays(record: ClipRecord, side: PlayerSide) -> list[np.ndarray | None]:
    """Per frame, the (2, 3) wrist keypoints of one player, or None."""
    out: list[np.ndarray | None] = []
    for f in record.frames:
        p = getattr(f.players, side)
        if p is None or len(p.keypoints) <= RIGHT_WRIST:
            out.append(None)
        else:
            out.append(np.array([p.keypoints[LEFT_WRIST], p.keypoints[RIGHT_WRIST]], float))
    return out


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill record.hits with (id, frame, time_s, player)."""
    from shuttlesense.tracking import track_arrays

    cfg = dict(ctx.stage_config("hits"))
    cfg["scale"] = (record.height or 720) / 720
    xy, visible = track_arrays(record)
    hits = detect_hits(
        np.nan_to_num(xy), visible, wrist_arrays(record, "near"), wrist_arrays(record, "far"), cfg
    )
    fps = record.fps or 30.0
    record.hits = [
        Hit(id=i, frame=frame, time_s=round(frame / fps, 3), player=side)
        for i, (frame, side) in enumerate(hits)
    ]
    ctx.progress(1.0)
    return record
