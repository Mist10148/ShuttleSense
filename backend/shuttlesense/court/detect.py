"""Conservative line-based suggestions for a fixed, end-on badminton court."""

from itertools import combinations

import cv2
import numpy as np

from shuttlesense.court.homography import check_court_area, validate_corners


def detect_corners(frame: np.ndarray) -> list[list[float]] | None:
    """Find singles baseline/sideline intersections; return None when evidence is weak.

    The detector expects a full court viewed from behind an end. It scores the projected
    service lines as well as the outline, and never substitutes generic screen coordinates.
    """
    height, width = frame.shape[:2]
    scale = min(1.0, 800 / width)
    image = cv2.resize(frame, (round(width * scale), round(height * scale)))
    h, w = image.shape[:2]
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    edges = cv2.Canny(gray, 50, 150)
    lines = cv2.HoughLinesP(
        edges, 1, np.pi / 180, threshold=max(25, w // 25), minLineLength=w // 9, maxLineGap=w // 35
    )
    if lines is None:
        return None
    horizontal, sides = [], []
    for x1, y1, x2, y2 in lines.reshape(-1, 4):
        dx, dy = float(x2 - x1), float(y2 - y1)
        length = np.hypot(dx, dy)
        if abs(dx) > 2 * abs(dy):
            horizontal.append((length, np.array([x1, y1, x2, y2], dtype=float)))
        elif abs(dy) > 0.55 * abs(dx):
            sides.append((length, np.array([x1, y1, x2, y2], dtype=float)))

    def unique(items, horizontal_axis):
        result = []
        for _, line in sorted(items, key=lambda item: -item[0]):
            # Merge duplicate edges of the same painted line at the image centre.
            x1, y1, x2, y2 = line
            value = (
                (y1 + (w / 2 - x1) * (y2 - y1) / (x2 - x1))
                if horizontal_axis
                else (x1 + (h / 2 - y1) * (x2 - x1) / (y2 - y1))
            )
            if all(abs(value - previous) > 7 for previous, _ in result):
                result.append((value, line))
            if len(result) == 10:
                break
        return result

    horizontal, sides = unique(horizontal, True), unique(sides, False)
    # Court markings are thin, light strokes, rather than arbitrary high-contrast
    # edges (advertising boards and spectators also generate strong Canny edges).
    top_hat = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT, np.ones((9, 9), np.uint8))
    markings = np.where((top_hat >= 18) & (gray >= 95), 255, 0).astype(np.uint8)
    distance = cv2.distanceTransform(255 - markings, cv2.DIST_L2, 3)
    best, best_score = None, 0.0
    samples = np.linspace(0.05, 0.95, 30)
    # Outline and both short service lines, in singles court coordinates.
    segments = [
        ((0, 0), (1, 0)),
        ((0, 1), (1, 1)),
        ((0, 0), (0, 1)),
        ((1, 0), (1, 1)),
        ((0, 0.3522), (1, 0.3522)),
        ((0, 0.6478), (1, 0.6478)),
        ((0.5, 0), (0.5, 0.3522)),
        ((0.5, 0.6478), (0.5, 1)),
    ]
    points = np.array(
        [
            [(1 - t) * a[0] + t * b[0], (1 - t) * a[1] + t * b[1]]
            for a, b in segments
            for t in samples
        ],
        dtype=np.float32,
    )

    def intersect(a, b):
        p, q = (
            np.cross(np.r_[a[:2], 1], np.r_[a[2:], 1]),
            np.cross(np.r_[b[:2], 1], np.r_[b[2:], 1]),
        )
        cross = np.cross(p, q)
        return cross[:2] / cross[2] if abs(cross[2]) > 1e-6 else np.array([np.inf, np.inf])

    for (_, near), (_, far) in combinations(
        sorted(horizontal, reverse=True, key=lambda x: x[0]), 2
    ):
        for (_, left), (_, right) in combinations(sorted(sides, key=lambda x: x[0]), 2):
            corners = np.array(
                [
                    intersect(near, left),
                    intersect(near, right),
                    intersect(far, right),
                    intersect(far, left),
                ],
                dtype=np.float32,
            )
            if (
                not np.isfinite(corners).all()
                or (corners < 0).any()
                or (corners[:, 0] >= w).any()
                or (corners[:, 1] >= h).any()
            ):
                continue
            near_width = np.linalg.norm(corners[1] - corners[0])
            far_width = np.linalg.norm(corners[2] - corners[3])
            near_y = (corners[0, 1] + corners[1, 1]) / 2
            far_y = (corners[2, 1] + corners[3, 1]) / 2
            # This detector is designed for a camera looking from behind a baseline.
            # Reject upside-down or reversed perspective before evaluating line support.
            if near_width < 1.05 * far_width or near_y - far_y < 0.15 * h:
                continue
            try:
                validate_corners(corners)
                check_court_area(corners, (w, h))
            except ValueError:
                continue
            transform = cv2.getPerspectiveTransform(
                np.array([[0, 0], [1, 0], [1, 1], [0, 1]], dtype=np.float32), corners
            )
            projected = cv2.perspectiveTransform(points.reshape(-1, 1, 2), transform).reshape(-1, 2)
            xs = np.clip(np.rint(projected[:, 0]).astype(int), 0, w - 1)
            ys = np.clip(np.rint(projected[:, 1]).astype(int), 0, h - 1)
            support = (distance[ys, xs] <= 3).reshape(len(segments), -1).mean(axis=1)
            score = float(np.mean(support))
            if min(support[:6]) >= 0.35 and min(support[6:]) >= 0.25 and score > best_score:
                best, best_score = corners, score
    if best is None or best_score < 0.65:
        return None
    return (best / scale).astype(float).tolist()
