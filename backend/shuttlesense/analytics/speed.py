"""Estimated shuttle speed from court-plane displacement (F11, FR-11).

Always an estimate: one camera gives a 2D court-plane approximation, which underestimates
shots travelling toward or away from the camera.
"""

from __future__ import annotations

import numpy as np

MAX_PLAUSIBLE_KMH = 450.0


def speeds_kmh(court_xy_m: np.ndarray, fps: float, smooth: int = 3, max_gap: int = 2) -> np.ndarray:
    """Per-frame speed in km/h from (N, 2) court positions in meters; NaN rows are unknown.

    A frame's speed uses the previous valid position if it is at most `max_gap` frames
    back; otherwise (start of the track or after a longer gap) it is NaN. The first valid
    frame of a run takes the next frame's speed. Values above MAX_PLAUSIBLE_KMH become NaN
    before `smooth` (a NaN-aware moving average), so one glitch frame does not raise the
    speed of its neighbours.
    """
    xy = np.asarray(court_xy_m, dtype=float)
    n = len(xy)
    raw = np.full(n, np.nan)
    valid = ~np.isnan(xy).any(axis=1) if n else np.zeros(0, bool)
    last = None
    for i in range(n):
        if not valid[i]:
            continue
        if last is not None and i - last <= max_gap:
            raw[i] = np.linalg.norm(xy[i] - xy[last]) / (i - last) * fps
        last = i
    # The first frame of each run borrows the next frame's speed.
    for i in range(n - 1):
        if valid[i] and np.isnan(raw[i]) and not np.isnan(raw[i + 1]):
            raw[i] = raw[i + 1]
    kmh = raw * 3.6
    kmh[kmh > MAX_PLAUSIBLE_KMH] = np.nan
    if smooth > 1:
        half = smooth // 2
        smoothed = np.full(n, np.nan)
        for i in np.flatnonzero(~np.isnan(kmh)):
            window = kmh[max(0, i - half) : i + half + 1]
            smoothed[i] = np.nanmean(window)
        kmh = smoothed
    return kmh


def hit_speed(kmh: np.ndarray, hit_frame: int, after: int = 5) -> float | None:
    """Peak speed in the `after` frames following a hit, or None."""
    window = kmh[hit_frame + 1 : hit_frame + 1 + after]
    if len(window) == 0 or np.isnan(window).all():
        return None
    return float(np.nanmax(window))
