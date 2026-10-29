"""Estimated shuttle speed from court-plane displacement (F11, FR-11).

Always an estimate: one camera gives a 2D court-plane approximation.
"""

from __future__ import annotations

import numpy as np


def speeds_kmh(court_xy_m: np.ndarray, fps: float, smooth: int = 3) -> np.ndarray:
    """Per-frame speed in km/h from (N, 2) court positions in meters.

    The first frame gets the second frame's speed. `smooth` is a moving-average window.
    TODO(T5.6): handle invisible frames (NaN) and replace the moving average with
    Savitzky-Golay smoothing if it is too noisy.
    """
    if len(court_xy_m) < 2:
        return np.zeros(len(court_xy_m))
    step = np.linalg.norm(np.diff(court_xy_m, axis=0), axis=1)
    mps = np.concatenate([[step[0]], step]) * fps
    if smooth > 1:
        kernel = np.ones(smooth) / smooth
        mps = np.convolve(mps, kernel, mode="same")
    return mps * 3.6
