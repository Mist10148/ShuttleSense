"""Homography from 4 tapped court corners (F9, FR-9).

Corner order (see docs/DATA_FORMAT.md): near-left, near-right, far-right, far-left.
Court coordinates are meters with the origin at the near-left corner.
"""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np

from shuttlesense.schema import COURT_SIZE_M, ClipRecord, Court, Point
from shuttlesense.stage import StageContext, StageSkipped


def court_corners_m(size: Point = COURT_SIZE_M) -> np.ndarray:
    width, length = size
    return np.array([[0.0, 0.0], [width, 0.0], [width, length], [0.0, length]], dtype=np.float32)


def validate_corners(corners: Sequence[Sequence[float]]) -> None:
    """Raise ValueError unless corners are 4 points forming a convex quadrilateral."""
    pts = np.asarray(corners, dtype=float)
    if pts.shape != (4, 2):
        raise ValueError("court corners must be 4 [x, y] points")
    cross = []
    for i in range(4):
        ab = pts[(i + 1) % 4] - pts[i]
        bc = pts[(i + 2) % 4] - pts[(i + 1) % 4]
        cross.append(ab[0] * bc[1] - ab[1] * bc[0])
    if not (all(c > 0 for c in cross) or all(c < 0 for c in cross)):
        raise ValueError("court corners must form a convex quadrilateral in the documented order")


def compute_homography(
    corners_px: Sequence[Sequence[float]], size: Point = COURT_SIZE_M
) -> np.ndarray:
    """3x3 matrix mapping image pixels to court meters."""
    import cv2

    validate_corners(corners_px)
    src = np.asarray(corners_px, dtype=np.float32)
    return cv2.getPerspectiveTransform(src, court_corners_m(size))


def _apply(h: np.ndarray, points: np.ndarray) -> np.ndarray:
    points = np.asarray(points, dtype=float).reshape(-1, 2)
    pts = np.hstack([points, np.ones((len(points), 1))])
    mapped = pts @ np.asarray(h, dtype=float).T
    return mapped[:, :2] / mapped[:, 2:3]


def image_to_court(h: np.ndarray, points_px: np.ndarray) -> np.ndarray:
    """Project (N, 2) pixel points onto the court plane."""
    return _apply(h, points_px)


def court_to_image(h: np.ndarray, points_m: np.ndarray) -> np.ndarray:
    """Project (N, 2) court points (meters) back to image pixels (for drawing)."""
    return _apply(np.linalg.inv(np.asarray(h, dtype=float)), points_m)


def check_court_area(
    corners_px: Sequence[Sequence[float]],
    frame_size: tuple[int, int],
    min_frac: float = 0.10,
    max_frac: float = 0.95,
) -> None:
    """Raise ValueError("corners look wrong") unless the court covers 10-95% of the frame."""
    pts = np.asarray(corners_px, dtype=float)
    x, y = pts[:, 0], pts[:, 1]
    area = 0.5 * abs(float(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1))))
    frac = area / max(frame_size[0] * frame_size[1], 1)
    if not min_frac <= frac <= max_frac:
        raise ValueError(f"corners look wrong: the court covers {frac:.0%} of the frame")


def job_corners(ctx: StageContext) -> list[list[float]] | None:
    """The job's court corners in the record's pixels, snapped onto the painted lines.

    The app taps corners on the source frame; the record uses normalized pixels. With
    `stages.court.refine` the taps are then nudged onto the court markings of the first
    frame (court/refine.py), or left as tapped when the markings do not support a better
    fit. Every stage that needs the court calls this, so all of them use one calibration;
    the result is remembered on the job's config.
    """
    from shuttlesense.court.refine import DEFAULTS, refine_corners

    corners = ctx.config.get("court_corners_px")
    if not corners:
        return None
    if "_court_corners" in ctx.config:
        return ctx.config["_court_corners"]
    corners = [[float(x), float(y)] for x, y in corners]
    reader = ctx.reader
    if reader is not None and reader.resized:
        sx = reader.width / reader.source.width
        sy = reader.height / reader.source.height
        corners = [[x * sx, y * sy] for x, y in corners]
    cfg = {**DEFAULTS, **ctx.stage_config("court")}
    if cfg["refine"] and reader is not None:
        frame = next((f for _, f in reader), None)
        if frame is not None:
            size = tuple(cfg.get("court_size_m", COURT_SIZE_M))
            refined, _ = refine_corners(
                frame,
                corners,
                size,
                max_shift_px=float(cfg["refine_max_shift_px"]),
                min_support=float(cfg["refine_min_support"]),
            )
            try:
                validate_corners(refined)
                corners = refined
            except ValueError:
                pass
    ctx.config["_court_corners"] = corners
    return corners


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill record.court from the job's corners (ctx.config["court_corners_px"])."""
    corners = job_corners(ctx)
    if not corners:
        raise StageSkipped("no court corners provided")
    size = tuple(ctx.stage_config("court").get("court_size_m", COURT_SIZE_M))
    h = compute_homography(corners, size)
    record.court = Court(
        corners_px=tuple(tuple(c) for c in corners), homography=h.tolist(), court_size_m=size
    )
    ctx.progress(1.0)
    return record
