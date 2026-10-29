"""Rally state, landing and in/out, and the referee stage (F14–F16, FR-14–FR-16).

In/out calls and the score are estimates: close calls are flagged as uncertain (no winner
is awarded) and the app always allows a manual correction.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

from shuttlesense.schema import ClipRecord, Landing, PlayerSide, Rally, Score, ScorePair
from shuttlesense.stage import StageContext, StageSkipped

STATIONARY_PX = 3.0
LINE_CONFIDENCE_M = 0.3  # confidence reaches 1 this far from the nearest line


@dataclass(frozen=True)
class Segment:
    start: int
    end: int
    closed: bool  # False when the clip ends mid-rally
    landing_frame: int | None  # where the shuttle came to rest, if seen


def _rest_after(
    visible: np.ndarray, xy: np.ndarray, frame: int, stop: int, cfg: dict[str, Any]
) -> tuple[int, int | None] | None:
    """First rally end in [frame, stop): (end frame, landing frame) or None if play goes on.

    End rules: the shuttle stays invisible for lost_frames_end frames (end = last visible
    frame, landing unknown unless it was resting), or it stays within STATIONARY_PX for
    stationary_frames_end frames (end = landing = first resting frame). A lost shuttle gives
    no landing call: it may have left the frame, so the user decides that rally.
    """
    lost = int(cfg.get("lost_frames_end", 30))
    still = int(cfg.get("stationary_frames_end", 20))
    last_visible, missing = frame, 0
    rest_start: int | None = None
    for i in range(frame, stop):
        if not visible[i]:
            missing += 1
            if missing >= lost:
                return last_visible, None
            continue
        moved = np.linalg.norm(xy[i] - xy[i - 1]) if i > frame and visible[i - 1] else None
        if moved is not None and moved < STATIONARY_PX:
            if rest_start is None:
                rest_start = i - 1
            if i - rest_start + 1 >= still:
                return rest_start, rest_start
        else:
            rest_start = None
        missing = 0
        last_visible = i
    return None


def segment_rallies(
    visible: np.ndarray, xy: np.ndarray, hits: list[int], cfg: dict[str, Any]
) -> list[Segment]:
    """Split a clip into rallies from hit frames and the shuttle trajectory.

    A rally starts at a hit following a pause of at least lost_frames_end frames (or at
    frame 0 when the clip starts with the shuttle already in play) and ends when the
    shuttle is lost or rests on the floor after its last hit. A rally still going at the
    end of the clip is left open.
    """
    n = len(visible)
    hits = sorted(h for h in hits if 0 <= h < n)
    if not hits:
        return []
    lost = int(cfg.get("lost_frames_end", 30))
    segments: list[Segment] = []
    k = 0
    while k < len(hits):
        start = hits[k]
        if not segments and start < lost and visible[:start].any():
            start = 0  # clip starts mid-rally: no serve seen
        while True:
            stop = hits[k + 1] if k + 1 < len(hits) else n
            rest = _rest_after(visible, xy, hits[k], stop, cfg)
            # A "rest" followed by another hit within lost_frames_end is detector noise:
            # a new rally needs a pause before its serve.
            if rest is not None and k + 1 < len(hits) and hits[k + 1] - rest[0] < lost:
                rest = None
            if rest is not None:
                end, landing = rest
                segments.append(Segment(start, end, True, landing))
                k += 1
                break
            if k + 1 >= len(hits):
                segments.append(Segment(start, n - 1, False, None))
                k += 1
                break
            k += 1  # next hit continues the same rally
    return segments


def landing_call(
    point_m: np.ndarray, size: tuple[float, float], margin_m: float
) -> tuple[bool, float]:
    """(in_court, confidence) for a landing point in court meters (singles lines are in)."""
    x, y = float(point_m[0]), float(point_m[1])
    w, length = size
    inside = 0.0 <= x <= w and 0.0 <= y <= length
    d = min(abs(x), abs(x - w), abs(y), abs(y - length))
    if not inside:
        # Outside: distance to the court rectangle, not to the far lines.
        dx = max(-x, 0.0, x - w)
        dy = max(-y, 0.0, y - length)
        d = float(np.hypot(dx, dy))
    confidence = min(1.0, d / LINE_CONFIDENCE_M)
    if d < margin_m:
        confidence = min(confidence, 0.49)
    return inside, round(confidence, 3)


def rally_winner(
    landing: Landing | None, last_hitter: PlayerSide | None, net_y: float
) -> PlayerSide | None:
    """In: the player on whose half it landed loses. Out: the last hitter loses.

    Uncertain calls (confidence < 0.5) award nobody; the user confirms them in the app.
    """
    if landing is None or landing.confidence < 0.5:
        return None
    if landing.in_court:
        return "far" if landing.y_m < net_y else "near"
    if last_hitter is None:
        return None
    return "far" if last_hitter == "near" else "near"


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill rallies[], hits[].rally_index, frames[].rally_state and score."""
    from shuttlesense.analytics.stage import count_strokes
    from shuttlesense.court import image_to_court
    from shuttlesense.referee.scoring import apply_rallies
    from shuttlesense.tracking import track_arrays

    if not record.hits:
        raise StageSkipped("no hits, so no rallies")
    cfg = ctx.stage_config("referee")
    xy, visible = track_arrays(record)
    segments = segment_rallies(visible, np.nan_to_num(xy), [h.frame for h in record.hits], cfg)

    size = record.court.court_size_m if record.court else None
    rallies = []
    for index, seg in enumerate(segments):
        landing = None
        if seg.closed and seg.landing_frame is not None and record.court is not None:
            point = image_to_court(np.asarray(record.court.homography), xy[[seg.landing_frame]])[0]
            inside, conf = landing_call(point, size, cfg.get("in_out_margin_m", 0.05))
            landing = Landing(x_m=round(float(point[0]), 3), y_m=round(float(point[1]), 3),
                              in_court=inside, confidence=conf)  # fmt: skip
        hits_in = [h for h in record.hits if seg.start <= h.frame <= seg.end]
        last = hits_in[-1].player if hits_in else None
        winner = rally_winner(landing, last, size[1] / 2) if size and seg.closed else None
        rallies.append(Rally(index=index, start_frame=seg.start, end_frame=seg.end,
                             landing=landing, winner=winner))  # fmt: skip
        for h in hits_in:
            h.rally_index = index

    for f in record.frames:
        inside = any(r.start_frame <= f.frame <= r.end_frame for r in rallies)
        f.rally_state = "in_play" if inside else "between_rallies"
    record.rallies = rallies
    count_strokes(record)
    start = ScorePair(**ctx.config.get("start_score", {}) or {})
    final = apply_rallies(record.rallies, start)
    record.score = Score(near=final.near, far=final.far)
    ctx.progress(1.0)
    return record
