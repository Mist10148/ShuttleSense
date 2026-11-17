"""Snap tapped court corners onto the painted lines (F9).

Four taps are rarely pixel-exact, and far from the camera one pixel covers several
centimetres of court, so a tap a few pixels off moves the far lines by more than the width
of a line. The lines themselves are in the picture: starting from the taps, each corner is
nudged until the projected court (outline, short service lines and centre lines) lies on the
painted markings. The result is kept only when the markings clearly support it and no corner
moved far; otherwise the taps stand as given.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

import numpy as np

from shuttlesense.court.lines import SHORT_SERVICE_FROM_NET_M
from shuttlesense.schema import COURT_SIZE_M, Point

DEFAULTS: dict[str, Any] = {
    "refine": True,
    "refine_max_shift_px": 12.0,  # at 720p: a tap further off than this is not "nudged"
    "refine_min_support": 0.6,  # share of the projected lines that must lie on markings
}
SUPPORT_PX = 2.0  # a projected point this close to a marking is on the line
CAP_PX = 6.0  # beyond this a point is simply "off": hidden by a player, or a wrong line
STEPS_PX = (4.0, 2.0, 1.0, 0.5)


def template_points(size: Point = COURT_SIZE_M, per_line: int = 30) -> np.ndarray:
    """(N, 2) points along the singles lines in the unit square (x across, y along)."""
    service = SHORT_SERVICE_FROM_NET_M / size[1]
    near, far = 0.5 - service, 0.5 + service
    segments = [
        ((0, 0), (1, 0)),
        ((0, 1), (1, 1)),
        ((0, 0), (0, 1)),
        ((1, 0), (1, 1)),
        ((0, near), (1, near)),
        ((0, far), (1, far)),
        ((0.5, 0), (0.5, near)),
        ((0.5, far), (0.5, 1)),
    ]
    t = np.linspace(0.03, 0.97, per_line)[:, None]
    return np.concatenate(
        [np.asarray(a) * (1 - t) + np.asarray(b) * t for a, b in segments]
    ).astype(np.float32)


def marking_distance(frame: np.ndarray) -> np.ndarray:
    """Signed distance in pixels to the court markings: 0 at a line's edge, positive away
    from it, negative inside it (down to the middle of the line).

    Markings are thin light strokes on a darker floor (a top-hat filter), not any strong
    edge: advertising boards and players have edges too.
    """
    import cv2

    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
    top_hat = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT, np.ones((9, 9), np.uint8))
    markings = np.where((top_hat >= 18) & (gray >= 95), 255, 0).astype(np.uint8)
    outside = cv2.distanceTransform(255 - markings, cv2.DIST_L2, 3)
    inside = cv2.distanceTransform(markings, cv2.DIST_L2, 3)
    return np.minimum(outside, CAP_PX) - np.minimum(inside, 3.0)


def _project(corners: np.ndarray, points: np.ndarray) -> np.ndarray:
    import cv2

    unit = np.float32([[0, 0], [1, 0], [1, 1], [0, 1]])
    transform = cv2.getPerspectiveTransform(unit, corners.astype(np.float32))
    return cv2.perspectiveTransform(points.reshape(-1, 1, 2), transform).reshape(-1, 2)


def _fit(distance: np.ndarray, corners: np.ndarray, points: np.ndarray) -> tuple[float, float]:
    """(mean signed distance of the projected lines, share of them on a marking); points
    that fall outside the picture count as off the lines."""
    h, w = distance.shape
    p = _project(corners, points)
    if not np.isfinite(p).all():
        return CAP_PX, 0.0
    xs, ys = np.rint(p[:, 0]).astype(int), np.rint(p[:, 1]).astype(int)
    inside = (xs >= 0) & (xs < w) & (ys >= 0) & (ys < h)
    d = np.full(len(p), CAP_PX)
    d[inside] = distance[ys[inside], xs[inside]]
    return float(d.mean()), float((d <= SUPPORT_PX).mean())


def refine_corners(
    frame: np.ndarray,
    corners: Sequence[Sequence[float]],
    size: Point = COURT_SIZE_M,
    *,
    max_shift_px: float = DEFAULTS["refine_max_shift_px"],
    min_support: float = DEFAULTS["refine_min_support"],
) -> tuple[list[list[float]], dict[str, float | bool]]:
    """(corners, report): the corners moved onto the painted lines, or as given.

    The report says whether they were refined, the line support before and after, and how
    far the furthest corner moved.
    """
    start = np.asarray(corners, dtype=float)
    scale = frame.shape[0] / 720
    distance = marking_distance(frame)
    points = template_points(size)
    cost, support = _fit(distance, start, points)
    report: dict[str, float | bool] = {
        "refined": False,
        "support_before": round(support, 3),
        "support_after": round(support, 3),
        "shift_px": 0.0,
    }
    best, best_cost = start.copy(), cost
    limit = max_shift_px * scale
    for step in STEPS_PX:
        step *= scale
        improved = True
        while improved:
            improved = False
            for k in range(4):
                for axis in (0, 1):
                    for sign in (-1.0, 1.0):
                        trial = best.copy()
                        trial[k, axis] += sign * step
                        if np.linalg.norm(trial[k] - start[k]) > limit:
                            continue
                        c, _ = _fit(distance, trial, points)
                        if c < best_cost - 1e-6:
                            best, best_cost, improved = trial, c, True
    _, after = _fit(distance, best, points)
    if after < min_support or after <= support or best_cost >= cost:
        return start.tolist(), report
    report.update(
        refined=True,
        support_after=round(after, 3),
        shift_px=round(float(np.linalg.norm(best - start, axis=1).max()), 2),
    )
    return best.tolist(), report
