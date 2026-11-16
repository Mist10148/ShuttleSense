"""Rule-based hit detector (F5, FR-5).

A hit is a frame where the shuttle's direction changes sharply while it is within
`max_wrist_distance_px` of a player's wrist. Thresholds live in configs/pipeline.yaml.

In doubles a side's wrists are both partners' wrists, so the side is found as in singles;
`attribute_hitters` then credits the hit to the partner whose wrist was closer (T9.5).
"""

from __future__ import annotations

from typing import Any

import numpy as np

from shuttlesense.schema import ClipRecord, Hit, PlayerId, PlayerSide, slot_attr
from shuttlesense.stage import StageContext
from shuttlesense.timing import scaled

# stages.hits keys that count frames.
FRAME_KEYS = ("min_frames_between_hits", "rally_break_frames", "hitter_window_frames")

LEFT_WRIST, RIGHT_WRIST = 9, 10
MIN_KEYPOINT_SCORE = 0.3


def direction_changes(xy: np.ndarray, min_angle_deg: float) -> list[int]:
    """Indices where the trajectory turns by more than `min_angle_deg`.

    xy: (N, 2) positions of consecutive visible frames.
    """
    if len(xy) < 3:
        return []
    v = np.diff(xy, axis=0)
    a, b = v[:-1], v[1:]
    norms = np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1)
    with np.errstate(invalid="ignore", divide="ignore"):
        cos = np.einsum("ij,ij->i", a, b) / norms
    angles = np.degrees(np.arccos(np.clip(np.nan_to_num(cos, nan=1.0), -1.0, 1.0)))
    return [i + 1 for i in np.flatnonzero(angles > min_angle_deg)]


def vertical_flips(xy: np.ndarray, min_px: float = 0.0) -> list[int]:
    """Indices where the shuttle stops moving down the image and starts moving up.

    Gravity never turns a falling shuttle upwards, so such a turn is a hit. Both steps must
    cover more than `min_px`: a shuttle held in the hand before a serve, or lying on the
    floor, jitters by a pixel or two in either direction and is not being hit. The opposite
    turn (up, then down) is the top of every flight, so it is not a candidate.
    """
    if len(xy) < 3:
        return []
    vy = np.diff(xy[:, 1])
    return [i + 1 for i in range(len(vy) - 1) if vy[i] > min_px and vy[i + 1] < -min_px]


def _wrist_distance(point: np.ndarray, wrists: np.ndarray | None) -> float:
    """Closest confident wrist to `point`; wrists is (N, 3) [x, y, score] or None."""
    if wrists is None:
        return float("inf")
    good = wrists[wrists[:, 2] >= MIN_KEYPOINT_SCORE]
    if len(good) == 0:
        return float("inf")
    return float(np.min(np.linalg.norm(good[:, :2] - point, axis=1)))


def same_rally(
    hidden: np.ndarray, a: int, b: int, break_len: int, unobserved: set[int] | None = None
) -> bool:
    """Whether frames a and b belong to one rally: the shuttle was never out of sight for
    `break_len` frames in between. `hidden` is per frame; unobserved frames (live mode: no
    perception ran) are neither hidden nor seen."""
    unobserved = unobserved or set()
    run = 0
    for f in range(a, b):
        if f in unobserved:
            continue
        run = run + 1 if hidden[f] else 0
        if run >= break_len:
            return False
    return True


def detect_hits(
    xy: np.ndarray,
    visible: np.ndarray,
    wrists_near: list[np.ndarray | None],
    wrists_far: list[np.ndarray | None],
    cfg: dict[str, Any],
    unobserved: set[int] | None = None,
) -> list[tuple[int, PlayerSide]]:
    """Hits as (frame, player), in frame order.

    Candidates are sharp direction changes and down-to-up flips within runs of consecutive
    visible frames: the jump across a gap that tracking left unfilled (the shuttle out of
    view, say) is not a movement of the shuttle. A candidate counts if a confident wrist is
    within max_wrist_distance_px (scaled by cfg["scale"], the frame height / 720); the
    closest player is the hitter. Within
    min_frames_between_hits only the closest-wrist candidate survives, and consecutive hits
    by the same player within a rally (impossible in singles) keep only the closer one.

    `unobserved` (live mode) are frames that got no perception. They are not evidence that
    the shuttle was out of view: a gap made only of them does not split a run, and they do
    not count towards a rally break.
    """
    unobserved = unobserved or set()
    idx = np.flatnonzero(np.asarray(visible) > 0)
    if len(idx) < 3:
        return []
    pts = np.asarray(xy, dtype=float)[idx]
    cand: set[int] = set()
    breaks = np.array(
        [k + 1 for k in np.flatnonzero(np.diff(idx) > 1)
         if any(f not in unobserved for f in range(int(idx[k]) + 1, int(idx[k + 1])))],
        dtype=int,
    )  # fmt: skip
    min_flip = float(cfg.get("min_flip_px", 0.0)) * cfg.get("scale", 1.0)
    for start, end in zip([0, *breaks], [*breaks, len(idx)], strict=True):
        run = pts[start:end]
        local = set(direction_changes(run, cfg.get("min_angle_deg", 60)))
        local |= set(vertical_flips(run, min_flip))
        cand |= {start + i for i in local}
    max_dist = cfg.get("max_wrist_distance_px", 120) * cfg.get("scale", 1.0)

    scored: list[tuple[float, int, PlayerSide]] = []
    for c in sorted(cand):
        frame = int(idx[c])
        d_near = _wrist_distance(pts[c], wrists_near[frame])
        d_far = _wrist_distance(pts[c], wrists_far[frame])
        d, side = (d_near, "near") if d_near <= d_far else (d_far, "far")
        if d <= max_dist:
            scored.append((d, frame, side))

    min_gap = cfg.get("min_frames_between_hits", 8)
    kept: list[tuple[float, int, PlayerSide]] = []
    for d, frame, side in sorted(scored):
        if all(abs(frame - k[1]) >= min_gap for k in kept):
            kept.append((d, frame, side))
    kept.sort(key=lambda k: k[1])

    # Across a rally break (the shuttle out of sight for rally_break_frames) the same player
    # may well hit twice in a row: the winner of a rally serves the next one.
    hidden = np.asarray(visible) <= 0
    break_len = int(cfg.get("rally_break_frames", 30))

    alternating: list[tuple[float, int, PlayerSide]] = []
    for hit in kept:
        if (
            alternating
            and alternating[-1][2] == hit[2]
            and same_rally(hidden, alternating[-1][1], hit[1], break_len, unobserved)
        ):
            if hit[0] < alternating[-1][0]:
                alternating[-1] = hit
            continue
        alternating.append(hit)
    return [(frame, side) for _d, frame, side in alternating]


def _wrists(p) -> np.ndarray | None:
    if p is None or len(p.keypoints) <= RIGHT_WRIST:
        return None
    return np.array([p.keypoints[LEFT_WRIST], p.keypoints[RIGHT_WRIST]], float)


def wrist_arrays(record: ClipRecord, side: str) -> list[np.ndarray | None]:
    """Per frame, the wrist keypoints [x, y, score] of a side, or None.

    `side` is near / far (with the partner's wrists too in doubles: (4, 3)) or one slot's
    Players field (near_2, ...: (2, 3)).
    """
    out: list[np.ndarray | None] = []
    for f in record.frames:
        arrays = [_wrists(getattr(f.players, side))]
        if side in ("near", "far"):
            arrays.append(_wrists(getattr(f.players, f"{side}_2")))
        found = [a for a in arrays if a is not None]
        out.append(np.concatenate(found) if found else None)
    return out


def partner_distances(
    record: ClipRecord, hit: Hit, xy: np.ndarray, visible: np.ndarray, window: int
) -> dict[PlayerId, float]:
    """Each partner's closest confident wrist to the shuttle within +-window frames of a hit
    (inf when the partner or the shuttle was not seen)."""
    slots: tuple[PlayerId, PlayerId] = (f"{hit.player}_1", f"{hit.player}_2")  # type: ignore[assignment]
    dist = {}
    for slot in slots:
        best = float("inf")
        for i in range(max(0, hit.frame - window), min(len(record.frames), hit.frame + window + 1)):
            if not visible[i]:
                continue
            wrists = _wrists(getattr(record.frames[i].players, slot_attr(slot)))
            best = min(best, _wrist_distance(xy[i], wrists))
        dist[slot] = best
    return dist


def closest_partner(record: ClipRecord, hit: Hit, cfg: dict[str, Any]) -> str | None:
    """Players field of the partner nearer the shuttle at a hit, however small the margin;
    None when neither was seen."""
    from shuttlesense.timing import frames_at
    from shuttlesense.tracking import track_arrays

    xy, visible = track_arrays(record)
    window = frames_at(cfg.get("hitter_window_frames", 3), record.fps)
    dist = partner_distances(record, hit, xy, visible, window)
    slot = min(dist, key=dist.get)
    return slot_attr(slot) if np.isfinite(dist[slot]) else None


def attribute_hitters(record: ClipRecord, cfg: dict[str, Any]) -> None:
    """Doubles: credit each hit to one partner (Hit.hitter, hitter_confidence).

    Within `hitter_window_frames` of the hit, each partner's closest confident wrist to the
    shuttle is measured; the closer partner hit it. When the two distances are within
    `ambiguous_px` (at 720p) of each other, or neither partner was seen, the hitter is left
    None and the app shows the team. The confidence grows with the gap between the two.
    Records without partners (singles) are left as they are.
    """
    if not any(f.players.near_2 or f.players.far_2 for f in record.frames):
        return
    from shuttlesense.tracking import track_arrays

    xy, visible = track_arrays(record)
    scale = float(cfg.get("scale", 1.0))
    window = int(cfg.get("hitter_window_frames", 3))
    ambiguous = float(cfg.get("ambiguous_px", 25)) * scale
    for hit in record.hits:
        dist = partner_distances(record, hit, xy, visible, window)
        a, b = dist
        da, db = dist[a], dist[b]
        if not np.isfinite(min(da, db)):
            hit.hitter, hit.hitter_confidence = None, None
            continue
        if np.isfinite(max(da, db)) and abs(da - db) < ambiguous:
            hit.hitter, hit.hitter_confidence = None, None
            continue
        closer, near_d, far_d = (a, da, db) if da <= db else (b, db, da)
        gap = 1.0 if not np.isfinite(far_d) else (far_d - near_d) / max(far_d + near_d, 1e-6)
        hit.hitter = closer
        hit.hitter_confidence = round(min(0.99, 0.5 + 0.5 * gap), 2)


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill record.hits with (id, frame, time_s, player)."""
    from shuttlesense.tracking import track_arrays

    # Frame counts in the config are for 30 fps; pixel distances for 720p.
    cfg = scaled(ctx.stage_config("hits"), FRAME_KEYS, record.fps)
    cfg["scale"] = (record.height or 720) / 720
    xy, visible = track_arrays(record)
    hits = detect_hits(
        np.nan_to_num(xy), visible, wrist_arrays(record, "near"), wrist_arrays(record, "far"), cfg,
        unobserved=set(ctx.config.get("_unobserved_frames", ())),
    )  # fmt: skip
    fps = record.fps or 30.0
    record.hits = [
        Hit(id=i, frame=frame, time_s=round(frame / fps, 3), player=side)
        for i, (frame, side) in enumerate(hits)
    ]
    attribute_hitters(record, cfg)
    ctx.progress(1.0)
    return record
