"""Court-plane positions for players and the shuttle (F10, FR-10).

Players stand on the court, so their foot point projects correctly: the ankle midpoint
(keypoints 15, 16) when both are confident, else the bottom-centre of the box.
The shuttle is in the air, so its projection is only an approximation (it lands
"behind" its true ground point when high); it is clamped to the court +- 1 m and used for
the minimap and speed estimates only. Speeds are labelled "estimated" everywhere.
"""

from __future__ import annotations

import numpy as np

from shuttlesense.schema import ClipRecord, CourtPositions, Player

LEFT_ANKLE, RIGHT_ANKLE = 15, 16
MIN_KEYPOINT_SCORE = 0.3


def player_point(p: Player, min_score: float = MIN_KEYPOINT_SCORE) -> tuple[float, float]:
    """Foot point in image pixels."""
    kps = p.keypoints
    if len(kps) > RIGHT_ANKLE and min(kps[LEFT_ANKLE][2], kps[RIGHT_ANKLE][2]) >= min_score:
        return (kps[LEFT_ANKLE][0] + kps[RIGHT_ANKLE][0]) / 2, (
            kps[LEFT_ANKLE][1] + kps[RIGHT_ANKLE][1]
        ) / 2
    x, y, w, h = p.bbox
    return x + w / 2, y + h


def smooth_nan(values: np.ndarray, window: int) -> np.ndarray:
    """Centred moving average over (N, D) values that ignores NaN rows and keeps them NaN."""
    if window <= 1 or len(values) == 0:
        return values.copy()
    out = np.full_like(values, np.nan, dtype=float)
    half = window // 2
    valid = ~np.isnan(values).any(axis=1)
    for i in np.flatnonzero(valid):
        lo, hi = max(0, i - half), min(len(values), i + half + 1)
        out[i] = values[lo:hi][valid[lo:hi]].mean(axis=0)
    return out


# Projections are clamped to the court plus a margin, so a homography far from the court
# (feet off the calibrated plane, a shuttle high in the air) cannot spike speeds.
PLAYER_MARGIN_M = 2.0
SHUTTLE_MARGIN_M = 1.0


def clamp_to_court(point: np.ndarray, size: tuple[float, float], margin: float) -> np.ndarray:
    """Clamp (..., 2) court points to the court expanded by `margin` meters."""
    width, length = size
    out = np.array(point, dtype=float)
    out[..., 0] = np.clip(out[..., 0], -margin, width + margin)
    out[..., 1] = np.clip(out[..., 1], -margin, length + margin)
    return out


def project_positions(
    record: ClipRecord,
    *,
    smooth: int = 5,
    player_margin_m: float = PLAYER_MARGIN_M,
    shuttle_margin_m: float = SHUTTLE_MARGIN_M,
    min_keypoint_score: float = MIN_KEYPOINT_SCORE,
) -> dict[str, np.ndarray]:
    """(N, 2) court positions per key ("near", "far", "shuttle", and "near_2", "far_2" in
    doubles); NaN where unknown."""
    from shuttlesense.court import image_to_court
    from shuttlesense.schema import is_doubles

    n = len(record.frames)
    players = ("near", "far", "near_2", "far_2") if is_doubles(record) else ("near", "far")
    out = {k: np.full((n, 2), np.nan) for k in (*players, "shuttle")}
    if record.court is None or n == 0:
        return out
    h = np.asarray(record.court.homography)
    width, length = record.court.court_size_m
    for i, f in enumerate(record.frames):
        for side in players:
            p = getattr(f.players, side)
            if p is not None and p.court_position_valid:
                out[side][i] = player_point(p, min_keypoint_score)
        s = f.shuttle
        if s is not None and s.visible and s.x is not None and s.y is not None:
            out["shuttle"][i] = s.x, s.y
    margins = [(key, player_margin_m) for key in players] + [("shuttle", shuttle_margin_m)]
    for key, margin in margins:
        px = out[key]
        valid = ~np.isnan(px).any(axis=1)
        if valid.any():
            px[valid] = clamp_to_court(image_to_court(h, px[valid]), (width, length), margin)
        if key != "shuttle":  # the shuttle is smoothed by the speed estimate instead
            out[key] = smooth_nan(px, smooth)
    return out


def apply_positions(record: ClipRecord, positions: dict[str, np.ndarray]) -> ClipRecord:
    """Write frames[].court_positions (null without a calibrated court)."""
    if record.court is None:
        for f in record.frames:
            f.court_positions = None
        return record

    def point(arr: np.ndarray, i: int):
        if np.isnan(arr[i]).any():
            return None
        return round(float(arr[i][0]), 3), round(float(arr[i][1]), 3)

    for i, f in enumerate(record.frames):
        f.court_positions = CourtPositions(
            near=point(positions["near"], i),
            far=point(positions["far"], i),
            shuttle=point(positions["shuttle"], i),
        )
        if "near_2" in positions:
            f.court_positions.near_2 = point(positions["near_2"], i)
            f.court_positions.far_2 = point(positions["far_2"], i)
    return record
