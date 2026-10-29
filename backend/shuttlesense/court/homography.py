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


def image_to_court(h: np.ndarray, points_px: np.ndarray) -> np.ndarray:
    """Project (N, 2) pixel points onto the court plane."""
    pts = np.hstack([points_px, np.ones((len(points_px), 1))])
    mapped = pts @ h.T
    return mapped[:, :2] / mapped[:, 2:3]


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill record.court from the job's corners (ctx.config["court_corners_px"])."""
    corners = ctx.config.get("court_corners_px")
    if not corners:
        raise StageSkipped("no court corners provided")
    # The app taps corners on the source frame; the record uses normalized pixels.
    if ctx.reader is not None and ctx.reader.resized:
        sx = ctx.reader.width / ctx.reader.source.width
        sy = ctx.reader.height / ctx.reader.source.height
        corners = [[x * sx, y * sy] for x, y in corners]
    h = compute_homography(corners)
    record.court = Court(corners_px=tuple(tuple(c) for c in corners), homography=h.tolist())
    ctx.progress(1.0)
    return record
