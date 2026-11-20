"""Flight-segment fitting of a shuttle track (F2, D43).

Between two hits a shuttle flies one smooth curve; at a hit it turns sharply. This module
uses that and nothing else, so it needs no labelled data to tune:

1. Each detection is predicted from the frames just before it and from the frames just
   after it (a short line fit on each side). When both sides agree with each other but not
   with the detection, the detection is a false one and is dropped. When both sides agree
   with the detection but point in clearly different directions (or the shuttle stops
   falling and starts rising), the detection is a turn and ends a flight segment.
2. Inside a segment, points are smoothed by a local quadratic (Savitzky-Golay style, with
   Huber weights so a bad point pulls little), never across a turn or a long gap; turn
   points themselves are kept as detected. A point far from the leave-one-out local fit
   is dropped as well.
3. A gap inside a segment is filled from one robust quadratic fitted to the points on both
   sides of it, but only when that one curve fits both sides well: a hit hidden in the gap
   leaves two flights that one quadratic cannot follow, and the gap is left alone.

All of it is NumPy only and vectorized per pass. Pixel thresholds are for 720p and scaled
by the image row like the outlier thresholds (`postprocess.depth_scale`).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import numpy as np

SIDE_POINTS = 3  # detections each side for the one-sided line fits
SIDE_MAX_FRAMES = 8  # ... no further away than this many frames
MAX_SKIP = 2  # one-sided fits may step over this many nearest points (a short burst)
LOO_REJECT_FACTOR = 2.0  # leave-one-out misses beyond this x reject_px are dropped too
END_REJECT_FACTOR = 5.0  # a run's end point this x reject_px off its one side is dropped
STOP_RATIO = 3.0  # one side this many times faster than the other (and moving) = a stop
TURN_MAX_STEP = 2  # frames to the nearest point on each side for a turn to be judged
HUBER_PX = 3.0  # residual beyond which a point's weight falls off (about 1.5 x the noise)
MAX_REJECT_PASSES = 3


@dataclass
class RefinedTrack:
    xy: np.ndarray  # (N, 2): smoothed detections and fitted gap frames; other rows as given
    kept: np.ndarray  # (N,) int: detections kept
    filled: np.ndarray  # (N,) bool: gap frames filled from a fitted flight
    breaks: list[int] = field(default_factory=list)  # frames where one flight ends, the next starts
    segments: list[tuple[int, int]] = field(default_factory=list)  # first, last frame


def _settings(settings: dict[str, Any] | None) -> dict[str, Any]:
    from shuttlesense.tracking.postprocess import precision_settings

    return precision_settings(settings)


def _row_scale(y: np.ndarray, height: float | None, cfg: dict[str, Any]) -> np.ndarray:
    from shuttlesense.tracking.postprocess import depth_scale

    if not cfg.get("depth_aware", True) or not height:
        return np.ones(len(y))
    return depth_scale(y, height, float(cfg["depth_far_scale"]), float(cfg["depth_near_scale"]))


def _side_points(
    frames: np.ndarray, alive: np.ndarray, direction: int, skip: int = 0
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Up to SIDE_POINTS live neighbours on one side of every point, leaving out the `skip`
    nearest ones (so a short burst next to the point is stepped over).

    Returns (index (M, K), frame offset (M, K), valid (M, K)).
    """
    m = len(frames)
    live = np.flatnonzero(alive)
    if direction < 0:
        start = np.searchsorted(live, np.arange(m)) - 1 - skip  # last live point before i
        steps = -np.arange(SIDE_POINTS)
    else:
        start = np.searchsorted(live, np.arange(m), side="right") + skip  # first after i
        steps = np.arange(SIDE_POINTS)
    jpos = start[:, None] + steps[None, :]
    valid = (jpos >= 0) & (jpos < len(live))
    if len(live) == 0:
        return np.zeros_like(jpos), np.zeros(jpos.shape), valid
    j = live[np.clip(jpos, 0, len(live) - 1)]
    t = (frames[j] - frames[:, None]).astype(float)
    valid &= np.abs(t) <= SIDE_MAX_FRAMES
    return j, t, valid


def _line_fits(
    frames: np.ndarray, pts: np.ndarray, alive: np.ndarray, direction: int, skip: int = 0
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Line fits through one side's neighbours (`_side_points`).

    Returns (prediction at the point's frame (M, 2), velocity per frame (M, 2), ok (M,)).
    """
    j, t, valid = _side_points(frames, alive, direction, skip)
    w = valid.astype(float)
    s0, s1, s2 = w.sum(1), (w * t).sum(1), (w * t * t).sum(1)
    y = pts[j]
    sy = (w[..., None] * y).sum(1)
    sty = (w[..., None] * t[..., None] * y).sum(1)
    det = s0 * s2 - s1 * s1
    ok = (valid.sum(1) >= 2) & (det > 1e-9)
    safe = np.where(ok, det, 1.0)[:, None]
    pred = (s2[:, None] * sy - s1[:, None] * sty) / safe
    vel = (s0[:, None] * sty - s1[:, None] * sy) / safe
    pred[~ok] = np.nan
    vel[~ok] = np.nan
    return pred, vel, ok


def _weighted_quadratics(
    t: np.ndarray, y: np.ndarray, w: np.ndarray, usable: np.ndarray
) -> tuple[np.ndarray, np.ndarray]:
    """Batched weighted least-squares quadratics: t, w (M, K), y (M, K, 2).

    Returns (coefficients (M, 3, 2), fitted values at t (M, K, 2)); rows not `usable` get
    zeros. Built from power sums, which is far quicker than a general solver per row.
    """
    t2 = t * t
    s = [w.sum(1), (w * t).sum(1), (w * t2).sum(1), (w * t2 * t).sum(1), (w * t2 * t2).sum(1)]
    a = np.empty((len(t), 3, 3))
    for i in range(3):
        for k in range(3):
            a[:, i, k] = s[i + k]
    wy = w[..., None] * y
    b = np.stack([wy.sum(1), (wy * t[..., None]).sum(1), (wy * t2[..., None]).sum(1)], axis=1)
    a[~usable] = np.eye(3)
    b[~usable] = 0.0
    a += 1e-9 * np.eye(3)
    coef = np.linalg.solve(a, b)
    fit = (
        coef[:, None, 0, :]
        + coef[:, None, 1, :] * t[..., None]
        + coef[:, None, 2, :] * t2[..., None]
    )
    return coef, fit


def _bridge_fits(
    frames: np.ndarray,
    pts: np.ndarray,
    back: tuple[np.ndarray, np.ndarray, np.ndarray],
    fwd: tuple[np.ndarray, np.ndarray, np.ndarray],
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """One quadratic through both sides' neighbours of every point, without the point.

    Returns (coefficients in frames from the point (M, 3, 2), worst residual of the fit
    (M,), ok (M,)): a small residual means both sides lie on one flight.
    """
    j = np.concatenate([back[0], fwd[0]], axis=1)
    t = np.concatenate([back[1], fwd[1]], axis=1)
    valid = np.concatenate([back[2], fwd[2]], axis=1)
    ok = (back[2].sum(1) >= 2) & (fwd[2].sum(1) >= 2)
    y = pts[j]
    coef, fit = _weighted_quadratics(t, y, valid.astype(float), ok)
    resid = np.linalg.norm(y - fit, axis=2)
    worst = np.where(valid, resid, 0.0).max(axis=1)
    return coef, worst, ok


def _off_curve(
    pts: np.ndarray,
    coef: np.ndarray,
    near: tuple[np.ndarray, np.ndarray, np.ndarray],
    count: int,
    tol: np.ndarray,
) -> np.ndarray:
    """Whether the `count` nearest points on one side (`near`: that side's points with no
    skip) all lie off the curve `coef`, or are missing: only then may a fit step over them."""
    off = np.ones(len(pts), dtype=bool)
    j, t, valid = near
    for k in range(count):
        tk = t[:, k][:, None]
        at = coef[:, 0, :] + coef[:, 1, :] * tk + coef[:, 2, :] * tk * tk
        far = np.linalg.norm(pts[j[:, k]] - at, axis=1) > tol
        off &= ~valid[:, k] | far
    return off


def _neighbour_gaps(frames: np.ndarray, alive: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Frames to the previous and to the next live point of every point (inf if none)."""
    m = len(frames)
    live = np.flatnonzero(alive)
    prev_gap = np.full(m, np.inf)
    next_gap = np.full(m, np.inf)
    before = np.searchsorted(live, np.arange(m)) - 1
    has = before >= 0
    prev_gap[has] = frames[has] - frames[live[before[has]]]
    after = np.searchsorted(live, np.arange(m), side="right")
    has = after < len(live)
    next_gap[has] = frames[live[after[has]]] - frames[has]
    return prev_gap, next_gap


def _angle(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    na, nb = np.linalg.norm(a, axis=1), np.linalg.norm(b, axis=1)
    with np.errstate(invalid="ignore", divide="ignore"):
        cos = np.einsum("ij,ij->i", a, b) / (na * nb)
    return np.degrees(np.arccos(np.clip(np.nan_to_num(cos, nan=1.0), -1.0, 1.0)))


def classify_points(
    frames: np.ndarray,
    pts: np.ndarray,
    scale: np.ndarray,
    cfg: dict[str, Any],
    *,
    reject: bool = True,
) -> tuple[np.ndarray, np.ndarray]:
    """(alive (M,) bool, turn (M,) bool) for visible points in frame order.

    A point is dropped (alive False) when one quadratic through the points on both sides
    of it (stepping over up to MAX_SKIP neighbours on each side) fits them within
    reject_px but misses the point by more; a point is a turn when line fits on its two
    sides point in directions more than split_angle_deg apart (or the shuttle goes from
    falling to rising) while both move at least min_split_speed_px per frame, or when the
    shuttle stops (or starts) abruptly: one side STOP_RATIO times faster than the other.
    """
    m = len(frames)
    alive = np.ones(m, dtype=bool)
    tol = float(cfg["reject_px"]) * scale
    split = float(cfg["split_angle_deg"])
    min_speed = float(cfg["min_split_speed_px"]) * scale
    skips = range(MAX_SKIP + 1)
    if reject:
        for _ in range(MAX_REJECT_PASSES):
            score = np.zeros(m)
            backs = [_side_points(frames, alive, -1, s) for s in skips]
            fwds = [_side_points(frames, alive, 1, s) for s in skips]
            back_l = [_line_fits(frames, pts, alive, -1, s) for s in skips]
            fwd_l = [_line_fits(frames, pts, alive, 1, s) for s in skips]
            near_b, near_f = back_l[0][0], fwd_l[0][0]
            on_line = (
                np.fmin(np.linalg.norm(pts - near_b, axis=1), np.linalg.norm(pts - near_f, axis=1))
                <= tol
            )
            for sb, back, (_pb, vb, _) in zip(skips, backs, back_l, strict=True):
                for sf, fwd, (_pf, vf, _) in zip(skips, fwds, fwd_l, strict=True):
                    coef, worst, ok = _bridge_fits(frames, pts, back, fwd)
                    pred = coef[:, 0, :]
                    # Points stepped over must be off the curve too (a burst), else the
                    # point is part of a short, sharp feature that the curve smooths over.
                    ok &= _off_curve(pts, coef, backs[0], sb, tol)
                    ok &= _off_curve(pts, coef, fwds[0], sf, tol)
                    # A sharp corner (a hit) is not an outlier, however badly one curve
                    # through it fits: there the two sides head different ways and the
                    # line through the nearest points of at least one side runs through it.
                    moving_b = np.linalg.norm(vb, axis=1) >= min_speed
                    moving_f = np.linalg.norm(vf, axis=1) >= min_speed
                    straight = (moving_b == moving_f) & (_angle(vb, vf) <= split)
                    agree = ok & alive & (worst <= tol) & (straight | ~on_line)
                    miss = np.linalg.norm(pts - pred, axis=1) / tol
                    score = np.fmax(score, np.where(agree, miss, 0.0))
            # The last points before a gap (or the first after one) have one side only: they
            # are dropped when they land far off where that side was heading.
            prev_gap, next_gap = _neighbour_gaps(frames, alive)
            for d, other_gap in ((-1, next_gap), (1, prev_gap)):
                pred, _v, ok = _line_fits(frames, pts, alive, d)
                lone = ok & (other_gap > SIDE_MAX_FRAMES) & alive
                e = np.linalg.norm(pts - pred, axis=1) / (END_REJECT_FACTOR * tol)
                score = np.fmax(score, np.where(lone, e, 0.0))
            bad = score > 1.0
            if not bad.any():
                break
            # Drop only the worst point of each neighbourhood: its neighbours' fits used it.
            local_max = np.ones(m, dtype=bool)
            for k in range(1, SIDE_POINTS + 1):
                local_max[k:] &= score[k:] >= score[:-k]
                local_max[:-k] &= score[:-k] > score[k:]
            alive &= ~(bad & local_max)
    _back, vb, okb = _line_fits(frames, pts, alive, -1)
    _fwd, vf, okf = _line_fits(frames, pts, alive, +1)
    # A turn needs the flight seen on both sides of it: next to a gap the two sides may
    # be far apart in time (the top of a flight hidden in the gap is not a hit).
    prev_gap, next_gap = _neighbour_gaps(frames, alive)
    adjacent = (prev_gap <= TURN_MAX_STEP) & (next_gap <= TURN_MAX_STEP)
    both = okb & okf & alive & adjacent
    sb, sf = np.linalg.norm(vb, axis=1), np.linalg.norm(vf, axis=1)
    moving = both & (sb >= min_speed) & (sf >= min_speed)
    angle = np.where(moving, _angle(vb, vf), 0.0)
    flip = both & (vb[:, 1] >= min_speed) & (vf[:, 1] <= -min_speed)
    # Next to a real corner a point or two see it too (their one-sided fits straddle it).
    # All of them are kept as detected, so the corner itself is never smoothed away.
    # Landing on the floor (or a catch): fast on one side, all but still on the other.
    fast, slow = np.fmax(sb, sf), np.fmin(sb, sf)
    stop = both & (fast >= STOP_RATIO * min_speed) & (fast >= STOP_RATIO * slow)
    turn = (angle > split) | flip | stop
    return alive, turn


def _segment_ids(frames: np.ndarray, turn: np.ndarray, max_gap: int) -> np.ndarray:
    """Segment number per point: a new segment after a turn point or a gap > max_gap. A
    turn point gets the id of the segment it ends (it also starts the next one)."""
    m = len(frames)
    seg = np.zeros(m, dtype=int)
    for i in range(1, m):
        new = turn[i - 1] or (frames[i] - frames[i - 1] - 1) > max_gap
        seg[i] = seg[i - 1] + int(new)
    return seg


def _local_quadratic(
    frames: np.ndarray,
    pts: np.ndarray,
    member: np.ndarray,
    half: int,
    *,
    exclude_self: bool,
    scale: np.ndarray,
    iters: int = 3,
) -> tuple[np.ndarray, np.ndarray]:
    """Huber-weighted quadratic through the points within +-half frames of each point.

    member: (M, S) bool, which segments each point belongs to (a turn point belongs to
    two); neighbours must share one. Returns (value at the point's frame (M, 2), number of
    neighbours used (M,)).
    """
    m = len(frames)
    offsets = np.arange(-half, half + 1)
    j = np.arange(m)[:, None] + offsets[None, :]
    valid = (j >= 0) & (j < m)
    jc = np.clip(j, 0, max(m - 1, 0))
    t = (frames[jc] - frames[:, None]).astype(float)
    valid &= np.abs(t) <= half
    valid &= (member[jc] & member[:, None, :]).any(axis=2)
    if exclude_self:
        valid &= offsets[None, :] != 0
    y = pts[jc]
    w = valid.astype(float)
    value = np.full((m, 2), np.nan)
    count = valid.sum(1)
    usable = count >= 4
    if not usable.any():
        return value, count
    huber = HUBER_PX * scale[:, None]
    for _ in range(iters):
        coef, fit = _weighted_quadratics(t, y, w, usable)
        r = np.linalg.norm(y - fit, axis=2)
        w = valid * np.minimum(1.0, huber / np.maximum(r, 1e-9))
    value[usable] = coef[usable, 0, :]
    return value, count


def _robust_quadratic(t: np.ndarray, y: np.ndarray, huber: float, iters: int = 5):
    """Per-axis quadratic fit (IRLS with Huber weights). Returns (coef (3, 2), residual
    norms (n,))."""
    x = np.stack([np.ones_like(t), t, t * t], axis=1)
    w = np.ones(len(t))
    coef = np.zeros((3, 2))
    for _ in range(iters):
        sw = np.sqrt(w)[:, None]
        coef, *_ = np.linalg.lstsq(x * sw, y * sw, rcond=None)
        r = np.linalg.norm(y - x @ coef, axis=1)
        w = np.minimum(1.0, huber / np.maximum(r, 1e-9))
    return coef, np.linalg.norm(y - x @ coef, axis=1)


def _fill_gaps(
    n: int,
    frames: np.ndarray,
    pts: np.ndarray,
    seg: np.ndarray,
    scale: np.ndarray,
    cfg: dict[str, Any],
) -> dict[int, np.ndarray]:
    """Gap frames -> position, for gaps inside a segment that one flight fits on both sides."""
    out: dict[int, np.ndarray] = {}
    context = int(cfg["fill_context"])
    max_gap = int(cfg["fill_max_gap"])
    for i in range(len(frames) - 1):
        a, b = int(frames[i]), int(frames[i + 1])
        gap = b - a - 1
        if gap < 1 or gap > max_gap or seg[i] != seg[i + 1]:
            continue
        left = (seg == seg[i]) & (frames <= a) & (frames >= a - context)
        right = (seg == seg[i]) & (frames >= b) & (frames <= b + context)
        if left.sum() < 3 or right.sum() < 3:
            continue
        use = left | right
        t = (frames[use] - a).astype(float)
        s = float(np.mean(scale[use]))
        coef, resid = _robust_quadratic(t, pts[use], HUBER_PX * s)
        limit = float(cfg["fill_max_rms_px"]) * s
        rms_l = float(np.sqrt(np.mean(resid[t <= 0] ** 2)))
        rms_r = float(np.sqrt(np.mean(resid[t > 0] ** 2)))
        if max(rms_l, rms_r) > limit:
            continue  # two flights, or one this model cannot follow: leave the gap
        tt = np.arange(1, gap + 1, dtype=float)
        fill = np.stack([np.ones_like(tt), tt, tt * tt], axis=1) @ coef
        for k, f in enumerate(range(a + 1, b)):
            if 0 <= f < n:
                out[f] = fill[k]
    return out


def smooth_points(
    frames: np.ndarray,
    pts: np.ndarray,
    *,
    settings: dict[str, Any] | None = None,
    frame_height: float | None = None,
    reject: bool = False,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Smooth visible points (frame numbers, (M, 2)) within flight segments.

    Returns (smoothed (M, 2), alive (M,) bool, turn (M,) bool). Turn points, points
    without enough neighbours in their segment and dropped points keep their positions.
    """
    cfg = _settings(settings)
    frames = np.asarray(frames, dtype=int)
    pts = np.asarray(pts, dtype=float)
    m = len(frames)
    if m < 3:
        return pts.copy(), np.ones(m, dtype=bool), np.zeros(m, dtype=bool)
    scale = _row_scale(pts[:, 1], frame_height, cfg)
    alive, turn = classify_points(frames, pts, scale, cfg, reject=reject)
    if reject:  # a point far from the leave-one-out fit of its own segment
        live = np.flatnonzero(alive)
        _, loo, count, plain = _segment_fit(frames, pts, alive, turn, scale, cfg, loo=True)
        limit = LOO_REJECT_FACTOR * float(cfg["reject_px"]) * scale[live]
        miss = np.linalg.norm(pts[live] - loo, axis=1) > limit
        alive[live[(count >= 4) & plain & miss]] = False
    out = _segment_fit(frames, pts, alive, turn, scale, cfg, loo=False)[0]
    return out, alive, turn


def _segment_fit(
    frames: np.ndarray,
    pts: np.ndarray,
    alive: np.ndarray,
    turn: np.ndarray,
    scale: np.ndarray,
    cfg: dict[str, Any],
    *,
    loo: bool,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """Local quadratic over the live points, segment by segment.

    Returns (all points with the smoothed ones replaced, the fit per live point, the
    neighbours used per live point, and which live points may be smoothed: not a turn and
    in a segment of at least min_segment_points).
    """
    out = pts.copy()
    live = np.flatnonzero(alive)
    if len(live) == 0:
        empty = np.zeros(0, dtype=bool)
        return out, np.zeros((0, 2)), np.zeros(0, dtype=int), empty
    lf, lp, ls, lt = frames[live], pts[live], scale[live], turn[live]
    seg = _segment_ids(lf, lt, int(cfg["fill_max_gap"]))
    member = np.zeros((len(live), int(seg.max()) + 2), dtype=bool)
    member[np.arange(len(live)), seg] = True
    member[np.flatnonzero(lt), seg[lt] + 1] = True  # a turn also starts the next segment
    sizes = np.bincount(seg, minlength=member.shape[1])
    plain = ~lt & (sizes[seg] >= int(cfg["min_segment_points"]))
    value, count = _local_quadratic(
        lf, lp, member, int(cfg["smooth_half_window"]), exclude_self=loo, scale=ls
    )
    ok = (count >= 4) & plain
    sm = lp.copy()
    sm[ok] = value[ok]
    out[live] = sm
    return out, value, count, plain


def refine_track(
    xy: np.ndarray,
    visible: np.ndarray,
    *,
    settings: dict[str, Any] | None = None,
    frame_height: float | None = None,
) -> RefinedTrack:
    """Fit the track (N frames) flight by flight: drop points the flight disagrees with,
    smooth each segment on its own and fill gaps inside a segment from one fitted flight."""
    cfg = _settings(settings)
    xy = np.asarray(xy, dtype=float).copy()
    n = len(xy)
    kept = (np.asarray(visible) > 0).astype(int)
    filled = np.zeros(n, dtype=bool)
    frames = np.flatnonzero(kept)
    if len(frames) < 3:
        return RefinedTrack(xy, kept, filled)
    pts = xy[frames]
    smoothed, alive, turn = smooth_points(
        frames, pts, settings=cfg, frame_height=frame_height, reject=True
    )
    kept[frames[~alive]] = 0
    live = np.flatnonzero(alive)
    lf, lp, lt = frames[live], smoothed[live], turn[live]
    xy[lf] = lp
    seg = _segment_ids(lf, lt, int(cfg["fill_max_gap"]))
    scale = _row_scale(lp[:, 1], frame_height, cfg)
    for f, p in _fill_gaps(n, lf, lp, seg, scale, cfg).items():
        if not kept[f]:
            xy[f] = p
            filled[f] = True
    segments = []
    for s in np.unique(seg):
        members = lf[seg == s]
        segments.append((int(members[0]), int(members[-1])))
    return RefinedTrack(xy, kept, filled, [int(f) for f in lf[lt]], segments)


def turn_time(
    frames: np.ndarray,
    pts: np.ndarray,
    c: int,
    side: int = 4,
    *,
    lo: int | None = None,
    hi: int | None = None,
) -> float:
    """Sub-frame time of the turn at point `c`: where the flight before it meets the flight
    after it.

    Each side is fitted through up to `side` points next to `c` (not `c` itself), within
    points lo..hi (inclusive; e.g. up to the neighbouring turns): a quadratic with four or
    more points, else a line. The time is where the two curves come closest, searched
    within 1.5 frames of frames[c]; frames[c] when a side has fewer than two points.
    """
    frames = np.asarray(frames, dtype=float)
    pts = np.asarray(pts, dtype=float)
    lo = 0 if lo is None else max(0, lo)
    hi = len(frames) - 1 if hi is None else min(len(frames) - 1, hi)
    centre = float(frames[c])
    before = np.arange(max(lo, c - side), c)
    after = np.arange(c + 1, min(hi, c + side) + 1)
    if len(before) < 2 or len(after) < 2:
        return centre

    def fit(sel: np.ndarray) -> np.ndarray:
        t = frames[sel] - centre
        degree = 2 if len(sel) >= 4 else 1
        x = np.stack([t**k for k in range(degree + 1)], axis=1)
        coef, *_ = np.linalg.lstsq(x, pts[sel], rcond=None)
        return coef

    c1, c2 = fit(before), fit(after)
    grid = np.linspace(-1.5, 1.5, 61)

    def at(coef: np.ndarray) -> np.ndarray:
        return np.stack([grid**k for k in range(len(coef))], axis=1) @ coef

    gap = np.linalg.norm(at(c1) - at(c2), axis=1)
    return centre + float(grid[int(np.argmin(gap))])
