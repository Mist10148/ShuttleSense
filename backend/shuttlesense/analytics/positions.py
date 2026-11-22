"""Court-plane positions for players and the shuttle (F10, FR-10).

Players stand on the court, so their foot point projects correctly: the ankle midpoint
(keypoints 15, 16) when both are confident, or the lower ankle when the other foot is
clearly lifted, lowered from the ankle joint to the floor; else the bottom-centre of the
box. Positions are smoothed within runs of frames only, never across a gap (D44).
The shuttle is in the air, so its projection is only an approximation (it lands
"behind" its true ground point when high); it is clamped to the court +- 1 m and used for
the minimap and speed estimates only. Speeds are labelled "estimated" everywhere.
"""

from __future__ import annotations

import numpy as np

from shuttlesense.schema import ClipRecord, CourtPositions, Player

LEFT_ANKLE, RIGHT_ANKLE = 15, 16
MIN_KEYPOINT_SCORE = 0.3
# The ankle keypoint is the joint, 7 to 8 cm above the floor: about 4% of a standing
# player's box height. Mapped onto the floor as it is, the point lands beyond the player
# (a few centimetres at the near baseline, tens at the far one, where a pixel covers more
# court), always away from the camera. The point is lowered by this share of the box
# height, and never below the box, whose bottom edge is the sole of the shoe.
ANKLE_FLOOR_RATIO = 0.04
# One ankle more than this share of the box height above the other is a lifted foot (a
# lunge, a step, a jump off one leg): the player stands on the lower one, and the midpoint
# would place them between their feet, up to half a stride off.
LIFTED_ANKLE_RATIO = 0.10
# Nobody on a badminton court moves faster than this; a faster step between two frames is
# a pose glitch or an identity swap, and is clamped (D44).
MAX_PLAYER_SPEED_MPS = 8.0


def foot_source(
    p: Player,
    min_score: float = MIN_KEYPOINT_SCORE,
    *,
    lifted_ratio: float = LIFTED_ANKLE_RATIO,
) -> str:
    """Which point `player_point` uses: "ankles" (midpoint), "lower_ankle" (one foot
    lifted) or "box" (bottom-centre of the box, no confident ankles). For quality notes;
    the clip record has no field for it."""
    kps = p.keypoints
    if len(kps) <= RIGHT_ANKLE or min(kps[LEFT_ANKLE][2], kps[RIGHT_ANKLE][2]) < min_score:
        return "box"
    h = p.bbox[3]
    if h > 0 and abs(kps[LEFT_ANKLE][1] - kps[RIGHT_ANKLE][1]) > lifted_ratio * h:
        return "lower_ankle"
    return "ankles"


def player_point(
    p: Player,
    min_score: float = MIN_KEYPOINT_SCORE,
    ankle_floor_ratio: float = ANKLE_FLOOR_RATIO,
    *,
    lifted_ratio: float = LIFTED_ANKLE_RATIO,
) -> tuple[float, float]:
    """Foot point on the floor, in image pixels."""
    kps = p.keypoints
    x, y, w, h = p.bbox
    source = foot_source(p, min_score, lifted_ratio=lifted_ratio)
    if source != "box":
        left, right = kps[LEFT_ANKLE], kps[RIGHT_ANKLE]
        if source == "lower_ankle":  # image y grows down: the larger y is the planted foot
            ankle_x, ankle_y = (left[0], left[1]) if left[1] >= right[1] else (right[0], right[1])
        else:
            ankle_x, ankle_y = (left[0] + right[0]) / 2, (left[1] + right[1]) / 2
        floor_y = ankle_y + ankle_floor_ratio * h
        if h > 0 and ankle_y <= y + h:  # ankles inside the box: its bottom is the limit
            floor_y = min(floor_y, y + h)
        return ankle_x, floor_y
    return x + w / 2, y + h


def court_player_point(p: Player, min_score: float = MIN_KEYPOINT_SCORE) -> tuple[float, float]:
    """Estimate the player's support point from measured ankles and the shoe baseline."""
    x, y, w, h = p.bbox
    bottom = y + h
    ankles = [
        (ax, ay)
        for ax, ay, score in p.keypoints[LEFT_ANKLE : RIGHT_ANKLE + 1]
        if score >= min_score
        and x - 0.05 * w <= ax <= x + 1.05 * w
        and y <= ay <= bottom + 0.05 * h
    ]
    if len(ankles) == 2 and h > 0:
        upper, lower = sorted(ankles, key=lambda ankle: ankle[1])
        separation = (lower[1] - upper[1]) / h
        weight = min(1.0, max(0.0, (separation - 0.06) / 0.10))
        if lower[1] < bottom - 0.12 * h:
            weight = 0.0
        ax = (upper[0] + lower[0]) / 2 + weight * (lower[0] - upper[0]) / 2
        ay = (upper[1] + lower[1]) / 2 + weight * (lower[1] - upper[1]) / 2
        return ax, min(bottom, ay + ANKLE_FLOOR_RATIO * h)
    if len(ankles) == 1 and h > 0 and ankles[0][1] >= bottom - 0.12 * h:
        ax, ay = ankles[0]
        return ax, min(bottom, ay + ANKLE_FLOOR_RATIO * h)
    return x + w / 2, bottom


def _runs(valid: np.ndarray) -> list[tuple[int, int]]:
    """(start, end) of each run of consecutive True values, end exclusive."""
    edges = np.flatnonzero(np.diff(np.concatenate([[0], valid.astype(int), [0]])))
    return list(zip(edges[::2].tolist(), edges[1::2].tolist(), strict=True))


def _clamp_speed(run: np.ndarray, max_step: float) -> np.ndarray:
    """Limit each step of a run to `max_step`, forwards and backwards, and average the two
    passes so the clamp does not lag in either direction."""

    def one_way(values: np.ndarray) -> np.ndarray:
        out = values.copy()
        for i in range(1, len(out)):
            step = out[i] - out[i - 1]
            size = float(np.linalg.norm(step))
            if size > max_step:
                out[i] = out[i - 1] + step * (max_step / size)
        return out

    return (one_way(run) + one_way(run[::-1])[::-1]) / 2


def smooth_nan(
    values: np.ndarray,
    window: int,
    *,
    fps: float | None = None,
    max_speed: float = MAX_PLAYER_SPEED_MPS,
) -> np.ndarray:
    """Smooth (N, D) values within each run of non-NaN rows; NaN rows stay NaN.

    A centred median over `window` frames (shrinking at a run's ends) removes single-frame
    glitches without rounding a change of direction; nothing is ever averaged across a gap,
    where a player may have moved anywhere. With `fps`, each step is then limited to
    `max_speed` (units of the values per second, 8 m/s for court metres).
    """
    out = np.asarray(values, dtype=float).copy()
    if len(values) == 0:
        return out
    half = max(window, 1) // 2
    valid = ~np.isnan(out).any(axis=1)
    for start, end in _runs(valid):
        run = out[start:end].copy()
        if half > 0 and len(run) > 1:
            for i in range(len(run)):
                lo, hi = max(0, i - half), min(len(run), i + half + 1)
                out[start + i] = np.median(run[lo:hi], axis=0)
        if fps and len(run) > 1:
            out[start:end] = _clamp_speed(out[start:end], max_speed / fps)
    return out


def _smooth_court_players(points: np.ndarray, window: int, fps: float) -> np.ndarray:
    out = points.copy()
    if fps > 0 and len(out) >= 3:
        max_step = MAX_PLAYER_SPEED_MPS / fps
        with np.errstate(invalid="ignore"):
            steps = np.linalg.norm(np.diff(points, axis=0), axis=1)
            bypass = np.linalg.norm(points[2:] - points[:-2], axis=1)
            rejected = (steps[:-1] > max_step) & (steps[1:] > max_step) & (bypass <= 2 * max_step)
        out[np.flatnonzero(rejected) + 1] = np.nan

    valid = np.isfinite(out).all(axis=1)
    for start, end in _runs(valid):
        run = out[start:end].copy()
        for i in range(1, len(run) - 1):
            radius = min(window // 2, i, len(run) - i - 1)
            if radius > 0:
                samples = run[i - radius : i + radius + 1]
                # Use an observed point nearest to the median, so a split step does not
                # produce a location between unrelated x and y samples.
                median = np.median(samples, axis=0)
                if not np.array_equal(median, run[i]):
                    nearest = np.argmin(np.linalg.norm(samples - median, axis=1))
                    out[start + i] = samples[nearest]
    return out


def clamped_mask(
    points: np.ndarray, size: tuple[float, float], margin: float, tol: float = 1e-3
) -> np.ndarray:
    """(N,) True where a court point sits on the edge `clamp_to_court` pins projections to
    (its true place is somewhere beyond it); NaN rows are False."""
    pts = np.asarray(points, dtype=float).reshape(-1, 2)
    width, length = size
    with np.errstate(invalid="ignore"):
        edge = (
            (pts[:, 0] <= -margin + tol)
            | (pts[:, 0] >= width + margin - tol)
            | (pts[:, 1] <= -margin + tol)
            | (pts[:, 1] >= length + margin - tol)
        )
    return edge & ~np.isnan(pts).any(axis=1)


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
    refine_players: bool = False,
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
    estimate = court_player_point if refine_players else player_point
    for i, f in enumerate(record.frames):
        for side in players:
            p = getattr(f.players, side)
            if p is not None and p.court_position_valid:
                out[side][i] = estimate(p, min_keypoint_score)
        s = f.shuttle
        if s is not None and s.visible and s.x is not None and s.y is not None:
            out["shuttle"][i] = s.x, s.y
    margins = [(key, player_margin_m) for key in players] + [("shuttle", shuttle_margin_m)]
    for key, margin in margins:
        px = out[key]
        valid = ~np.isnan(px).any(axis=1)
        if valid.any():
            with np.errstate(divide="ignore", invalid="ignore"):
                projected = image_to_court(h, px[valid])
            px[valid] = clamp_to_court(projected, (width, length), margin)
            if refine_players and key != "shuttle":
                outside = clamped_mask(px, (width, length), margin)
                px[outside] = np.nan
        if key != "shuttle":  # the shuttle is smoothed by the speed estimate instead
            out[key] = (
                _smooth_court_players(px, smooth, record.fps)
                if refine_players
                else smooth_nan(px, smooth, fps=record.fps or None)
            )
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
