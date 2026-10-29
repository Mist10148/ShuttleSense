"""Fill short gaps in a shuttle trajectory (F2)."""

from __future__ import annotations

import numpy as np


def interpolate_gaps(
    xy: np.ndarray, visible: np.ndarray, max_gap: int
) -> tuple[np.ndarray, np.ndarray]:
    """Linearly interpolate runs of invisible frames no longer than `max_gap`.

    xy: (N, 2) float array; visible: (N,) array of 0/1.
    Gaps at the start or end, or longer than max_gap, stay invisible.
    """
    xy = xy.astype(float).copy()
    visible = visible.astype(int).copy()
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
        for k in range(1, gap + 1):
            xy[start + k - 1] = left + (k / (gap + 1)) * (right - left)
        visible[start:end] = 1
    return xy, visible
