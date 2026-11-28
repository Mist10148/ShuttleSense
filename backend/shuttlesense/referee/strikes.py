"""Who struck the shuttle last in a rally (D61).

An OUT call is decided by who struck the shuttle last, and the hit detector can miss a
touch: a mishit, a frame shot, a block at the net with the wrist hidden for a frame. So the
referee checks the track itself after the last detected hit. A sharp turn, or a falling
shuttle turning upwards (gravity never does that), within reach of a player's wrist is a
strike. It counts for a side only when that side's wrist is clearly the nearer one; a strike
nobody can be credited with leaves the last striker unknown, and an OUT call then waits for
the user rather than guessing (D45). A turn with no wrist anywhere near it (the net tape,
tracker noise) is not a strike.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from shuttlesense.schema import ClipRecord, Hit, PlayerSide

# Pixel distances are for 720p, frame counts for 30 fps; both are converted to the video.
HIDDEN_REACH_PX = 60.0  # a strike the detector missed: a wrist at most this far from the shuttle
REACH_PX = 120.0  # any wrist this close makes a turn a possible strike (stages.hits default)
CLEAR_RATIO = 0.5  # the striker's wrist is at most this share of the other side's distance
WINDOW_FRAMES = 3  # frames either side of a strike searched for the nearest wrist
MIN_GAP_FRAMES = 8  # turns closer than this to a hit or to each other are the same strike
MAX_GAP_FRAMES = 4  # a tracking gap longer than this splits the track
LANDING_FRAMES = 2  # turns this close to the landing are the shuttle meeting the floor
MIN_ANGLE_DEG = 60.0
MIN_FLIP_PX = 2.0
WRISTS = (9, 10)  # COCO left and right wrist
MIN_KEYPOINT_SCORE = 0.3


@dataclass(frozen=True)
class Striker:
    """The last strike of a rally before its landing."""

    side: PlayerSide | None  # None: a strike nobody can be credited with
    frame: int
    clear: bool  # one side's wrist was clearly the nearer one
    hidden: bool = False  # found on the track, not by the hit detector


def _scale(record: ClipRecord) -> tuple[float, float]:
    """(pixel scale, frame scale) of the record against 720p and 30 fps."""
    return (record.height or 720) / 720, (record.fps or 30.0) / 30.0


def _side_wrists(record: ClipRecord, frame: int, side: str) -> np.ndarray:
    """Confident wrists [x, y] of a side (both partners in doubles) at a frame."""
    players = record.frames[frame].players
    out = []
    for slot in (side, f"{side}_2"):
        p = getattr(players, slot, None)
        if p is None:
            continue
        for i in WRISTS:
            if i < len(p.keypoints) and p.keypoints[i][2] >= MIN_KEYPOINT_SCORE:
                out.append(p.keypoints[i][:2])
    return np.asarray(out, dtype=float).reshape(-1, 2)


def reach(
    record: ClipRecord, frame: int, xy: np.ndarray, visible: np.ndarray, window: int
) -> dict[str, float]:
    """Each side's nearest confident wrist to the shuttle within +-window frames (inf: none)."""
    best = {"near": float("inf"), "far": float("inf")}
    for i in range(max(0, frame - window), min(len(record.frames), frame + window + 1)):
        if not visible[i]:
            continue
        for side in best:
            wrists = _side_wrists(record, i, side)
            if len(wrists):
                best[side] = min(best[side], float(np.min(np.linalg.norm(wrists - xy[i], axis=1))))
    return best


def clearly(side: str, dist: dict[str, float], ratio: float = CLEAR_RATIO) -> bool:
    """Whether `side`'s wrist is clearly nearer the shuttle than the other side's."""
    other = dist["far" if side == "near" else "near"]
    own = dist[side]
    return bool(np.isfinite(own) and (not np.isfinite(other) or own <= ratio * other))


def turns(
    record: ClipRecord, xy: np.ndarray, visible: np.ndarray, start: int, stop: int
) -> list[int]:
    """Frames in [start, stop] where the track turns sharply or a falling shuttle rises.

    The same candidates as the hit detector (hits/detector.py), on runs of the track split
    at gaps longer than MAX_GAP_FRAMES, each smoothed within its flights.
    """
    from shuttlesense.hits.detector import direction_changes, smoothed_run, vertical_flips

    px, fr = _scale(record)
    idx = np.array([i for i in range(max(0, start), min(len(visible), stop + 1)) if visible[i]])
    if len(idx) < 3:
        return []
    gap = max(1, round(MAX_GAP_FRAMES * fr))
    cuts = [0, *[k + 1 for k in np.flatnonzero(np.diff(idx) > gap)], len(idx)]
    found: list[int] = []
    for a, b in zip(cuts[:-1], cuts[1:], strict=True):
        if b - a < 3:
            continue
        pts = smoothed_run(idx[a:b], xy[idx[a:b]].astype(float), {"min_angle_deg": MIN_ANGLE_DEG})
        local = set(direction_changes(pts, MIN_ANGLE_DEG)) | set(
            vertical_flips(pts, MIN_FLIP_PX * px)
        )
        found += [int(idx[a + k]) for k in local]
    return sorted(found)


def final_striker(
    record: ClipRecord,
    hits: list[Hit],
    landing_frame: int,
    xy: np.ndarray | None = None,
    visible: np.ndarray | None = None,
) -> Striker | None:
    """The last strike before the landing at `landing_frame`, or None without any hit.

    Starts from the last detected hit (credited to its detected side; `clear` says whether
    the wrists back that up) and moves on to every later turn with a wrist within reach.
    """
    if not hits:
        return None
    if xy is None or visible is None:
        xy, visible = track(record)
    px, fr = _scale(record)
    window = max(1, round(WINDOW_FRAMES * fr))
    min_gap = max(1, round(MIN_GAP_FRAMES * fr))
    last = hits[-1]
    if not 0 <= last.frame < len(record.frames):
        return Striker(last.player, last.frame, False)
    dist = reach(record, last.frame, xy, visible, window)
    striker = Striker(last.player, last.frame, clearly(last.player, dist))
    stop = landing_frame - max(1, round(LANDING_FRAMES * fr))
    for f in turns(record, xy, visible, last.frame + min_gap, stop):
        if f - striker.frame < min_gap:
            continue
        dist = reach(record, f, xy, visible, window)
        side = min(dist, key=dist.get)
        if dist[side] > REACH_PX * px:
            continue  # no wrist near: not a strike
        if dist[side] <= HIDDEN_REACH_PX * px and clearly(side, dist):
            striker = Striker(side, f, True, hidden=True)  # type: ignore[arg-type]
        else:
            striker = Striker(None, f, False, hidden=True)
    return striker


def tracked_after(
    visible: np.ndarray, xy: np.ndarray, frame: int, landing_frame: int, max_gap: int
) -> bool:
    """Whether the shuttle was seen from `frame` to its landing with no gap over `max_gap`.

    The last gap may be longer when the shuttle was coming down into it: a shuttle missed as
    it fell and found lying where it fell (D46). Any other long gap could hide a return.
    """
    seen = [i for i in range(frame, min(len(visible), landing_frame + 1)) if visible[i]]
    if len(seen) < 2:
        return False
    gaps = np.diff(seen)
    if (gaps[:-1] > max_gap).any():
        return False
    if gaps[-1] <= max_gap:
        return True
    before = seen[-2]
    falling = [i for i in seen[:-1] if before - i <= 8]
    return len(falling) >= 3 and xy[falling[-1]][1] > xy[falling[0]][1]


def track(record: ClipRecord) -> tuple[np.ndarray, np.ndarray]:
    """The shuttle track with the tracker's filled-in frames counted as unseen."""
    from shuttlesense.tracking import track_arrays

    xy, visible = track_arrays(record)
    visible = np.asarray(visible).copy()
    for i in record._estimated_shuttle_frames:
        if 0 <= i < len(visible):
            visible[i] = 0
    return np.nan_to_num(xy), visible
