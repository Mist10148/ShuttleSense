"""Fill short gaps in a shuttle trajectory (F2)."""

from __future__ import annotations

import numpy as np


def _velocity(xy: np.ndarray, visible: np.ndarray, a: int, b: int) -> np.ndarray | None:
    """Pixels per frame between two frames, when both are inside the clip and were seen."""
    if a < 0 or b >= len(visible) or not (visible[a] and visible[b]):
        return None
    return xy[b] - xy[a]


def interpolate_gaps(
    xy: np.ndarray, visible: np.ndarray, max_gap: int
) -> tuple[np.ndarray, np.ndarray]:
    """Fill runs of invisible frames no longer than `max_gap`.

    xy: (N, 2) float array; visible: (N,) array of 0/1.
    Gaps at the start or end, or longer than max_gap, stay invisible.

    The fill follows the flight on both sides of the gap (a cubic Hermite curve through the
    two end points with the velocities seen just before and just after), so a gap in a
    curved flight does not leave a corner that reads as a change of direction. Where a side
    has no velocity, the straight line between the end points stands in; a gap with neither
    is filled linearly. Velocities are capped at twice the gap's chord so a noisy neighbour
    cannot make the fill loop.
    """
    xy = xy.astype(float).copy()
    seen = visible.astype(int).copy()  # only real detections give a velocity
    visible = seen.copy()
    n = len(visible)
    i = 0
    while i < n:
        if visible[i]:
            i += 1
            continue
        start = i
        while i < n and not visible[i]:
            i += 1
        end = i  # first visible index after the gap, or n
        gap = end - start
        if start == 0 or end == n or gap > max_gap:
            continue
        left, right = xy[start - 1], xy[end]
        span = gap + 1
        chord = right - left
        limit = 2 * float(np.linalg.norm(chord))
        tangents = []
        for v in (_velocity(xy, seen, start - 2, start - 1), _velocity(xy, seen, end, end + 1)):
            m = chord if v is None else v * span
            size = float(np.linalg.norm(m))
            tangents.append(m * (limit / size) if size > limit and size > 0 else m)
        m0, m1 = tangents
        for k in range(1, gap + 1):
            s = k / span
            xy[start + k - 1] = (
                (2 * s**3 - 3 * s**2 + 1) * left
                + (s**3 - 2 * s**2 + s) * m0
                + (-2 * s**3 + 3 * s**2) * right
                + (s**3 - s**2) * m1
            )
        visible[start:end] = 1
    return xy, visible
