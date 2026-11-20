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


def template_segments(size: Point = COURT_SIZE_M) -> list[tuple[tuple[float, float], ...]]:
    """The singles lines as segments in the unit square (x across, y along)."""
    service = SHORT_SERVICE_FROM_NET_M / size[1]
    near, far = 0.5 - service, 0.5 + service
    return [
        ((0, 0), (1, 0)),
        ((0, 1), (1, 1)),
        ((0, 0), (0, 1)),
        ((1, 0), (1, 1)),
        ((0, near), (1, near)),
        ((0, far), (1, far)),
        ((0.5, 0), (0.5, near)),
        ((0.5, far), (0.5, 1)),
    ]


def template_points(size: Point = COURT_SIZE_M, per_line: int = 30) -> np.ndarray:
    """(N, 2) points along the singles lines in the unit square (x across, y along)."""
    t = np.linspace(0.03, 0.97, per_line)[:, None]
    return np.concatenate(
        [np.asarray(a) * (1 - t) + np.asarray(b) * t for a, b in template_segments(size)]
    ).astype(np.float32)


def template_directions(size: Point = COURT_SIZE_M, per_line: int = 30) -> np.ndarray:
    """(N, 2) unit direction of the line each `template_points` point lies on."""
    out = []
    for a, b in template_segments(size):
        d = np.asarray(b, dtype=float) - np.asarray(a, dtype=float)
        out.append(np.repeat((d / np.linalg.norm(d))[None, :], per_line, axis=0))
    return np.concatenate(out).astype(np.float32)


MARK_TOP_HAT = 18  # a marking is this much brighter than the floor around it ...
MARK_MIN_GRAY = 95  # ... and at least this bright


def _markings(frame: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(top-hat response, 0/255 marking mask) of a frame."""
    import cv2

    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
    top_hat = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT, np.ones((9, 9), np.uint8))
    markings = np.where((top_hat >= MARK_TOP_HAT) & (gray >= MARK_MIN_GRAY), 255, 0)
    return top_hat, markings.astype(np.uint8)


def marking_distance(frame: np.ndarray) -> np.ndarray:
    """Signed distance in pixels to the court markings: 0 at a line's edge, positive away
    from it, negative inside it (down to the middle of the line).

    Markings are thin light strokes on a darker floor (a top-hat filter), not any strong
    edge: advertising boards and players have edges too.
    """
    import cv2

    _, markings = _markings(frame)
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


LSQ_SEARCH_PX = 4.0  # at 720p: how far across a projected line its painted centre is sought
LSQ_ITERATIONS = 3
LSQ_MIN_POINTS = 0.5  # share of the template points that must find their line
LSQ_INLIER_PX = 1.5  # at 720p: RANSAC threshold for a line point


def _line_centres(
    top_hat: np.ndarray, image_pts: np.ndarray, normals: np.ndarray, search: float
) -> tuple[np.ndarray, np.ndarray]:
    """Sub-pixel centre of the painted line across each projected template point.

    The top-hat response is sampled along the line's normal within +-search px; the centre
    is the response-weighted mean offset of the samples above the marking threshold. Points
    whose profile is too weak, or peaks at the edge of the search (another line, or none),
    are not found. Returns (centres (N, 2), found (N,)).
    """
    import cv2

    offsets = np.arange(-search, search + 1e-6, 0.25, dtype=np.float32)
    samples = image_pts[:, None, :] + offsets[None, :, None] * normals[:, None, :]
    profile = cv2.remap(
        top_hat.astype(np.float32),
        samples[..., 0].astype(np.float32),
        samples[..., 1].astype(np.float32),
        cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=0.0,
    )
    peak = profile.max(axis=1)
    arg = profile.argmax(axis=1)
    weights = np.clip(profile - MARK_TOP_HAT, 0.0, None)
    found = (peak >= MARK_TOP_HAT * 1.5) & (arg > 1) & (arg < len(offsets) - 2)
    total = weights.sum(axis=1)
    found &= total > 0
    shift = (weights * offsets[None, :]).sum(axis=1) / np.where(total > 0, total, 1.0)
    return image_pts + shift[:, None] * normals, found


def fit_court_lines(
    frame: np.ndarray,
    corners: Sequence[Sequence[float]],
    size: Point = COURT_SIZE_M,
    *,
    per_line: int = 60,
) -> tuple[np.ndarray, dict[str, float]] | None:
    """Least-squares court fit over all the painted line points, not only 4 corners.

    Starting from `corners`, every template point (outline, short service and centre
    lines) is projected, the painted line's centre is found across it (`_line_centres`),
    and a homography from the unit court to the image is fitted to all those matches
    (RANSAC drops points on players or other markings, then least squares on the rest).
    Repeated a few times, as the matches move with the fit. Returns (corners (4, 2),
    report with the RMS reprojection error of the line points before and after, in px,
    and the share of points used), or None when too few line points were found.
    """
    import cv2

    scale = frame.shape[0] / 720
    top_hat, _ = _markings(frame)
    unit_pts = template_points(size, per_line)
    unit_dirs = template_directions(size, per_line)
    unit = np.float32([[0, 0], [1, 0], [1, 1], [0, 1]])
    h = cv2.getPerspectiveTransform(unit, np.asarray(corners, dtype=np.float32))
    first_rms: float | None = None
    rms, used = float("nan"), 0.0
    for _ in range(LSQ_ITERATIONS):
        img = cv2.perspectiveTransform(unit_pts.reshape(-1, 1, 2), h).reshape(-1, 2)
        ahead = cv2.perspectiveTransform((unit_pts + 1e-3 * unit_dirs).reshape(-1, 1, 2), h)
        tangent = ahead.reshape(-1, 2) - img
        tangent /= np.maximum(np.linalg.norm(tangent, axis=1, keepdims=True), 1e-9)
        normals = np.stack([-tangent[:, 1], tangent[:, 0]], axis=1)
        centres, found = _line_centres(top_hat, img, normals, LSQ_SEARCH_PX * scale)
        if found.mean() < LSQ_MIN_POINTS:
            return None
        if first_rms is None:
            first_rms = float(np.sqrt(np.mean(np.sum((centres[found] - img[found]) ** 2, 1))))
        src, dst = unit_pts[found], centres[found].astype(np.float32)
        h_new, inliers = cv2.findHomography(src, dst, cv2.RANSAC, LSQ_INLIER_PX * scale)
        if h_new is None:
            return None
        keep = inliers.ravel().astype(bool)
        h_new, _ = cv2.findHomography(src[keep], dst[keep], 0)  # least squares on inliers
        if h_new is None:
            return None
        h = h_new
        fitted = cv2.perspectiveTransform(src[keep].reshape(-1, 1, 2), h).reshape(-1, 2)
        rms = float(np.sqrt(np.mean(np.sum((fitted - dst[keep]) ** 2, axis=1))))
        used = float(keep.sum()) / len(unit_pts)
    out = cv2.perspectiveTransform(unit.reshape(-1, 1, 2), h).reshape(-1, 2)
    report = {
        "reprojection_px_before": round(first_rms or 0.0, 3),
        "reprojection_px": round(rms, 3),
        "line_points_used": round(used, 3),
    }
    return out.astype(float), report


def refine_corners(
    frame: np.ndarray,
    corners: Sequence[Sequence[float]],
    size: Point = COURT_SIZE_M,
    *,
    max_shift_px: float = DEFAULTS["refine_max_shift_px"],
    min_support: float = DEFAULTS["refine_min_support"],
    lsq: bool = True,
) -> tuple[list[list[float]], dict[str, float | bool]]:
    """(corners, report): the corners moved onto the painted lines, or as given.

    The report says whether they were refined, the line support before and after, and how
    far the furthest corner moved; with `lsq` (D43) also the RMS reprojection error of the
    painted line points before and after the least-squares fit (`fit_court_lines`).
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
    # The search above moves one corner at a time by at least half a pixel; a least-squares
    # fit over every line point found then settles the corners to a fraction of a pixel.
    if lsq:
        fit = fit_court_lines(frame, best, size)
        if fit is not None:
            corners_lsq, lsq_report = fit
            report.update(lsq_report)
            shift = np.linalg.norm(corners_lsq - start, axis=1).max()
            better = lsq_report["reprojection_px"] <= lsq_report["reprojection_px_before"]
            if better and shift <= limit and _convex(corners_lsq):
                best = corners_lsq
                report["least_squares"] = True
                _, after = _fit(distance, best, points)
    report.update(
        refined=True,
        support_after=round(after, 3),
        shift_px=round(float(np.linalg.norm(best - start, axis=1).max()), 2),
    )
    return best.tolist(), report


def _convex(corners: np.ndarray) -> bool:
    from shuttlesense.court.homography import validate_corners

    try:
        validate_corners(corners)
    except ValueError:
        return False
    return True
