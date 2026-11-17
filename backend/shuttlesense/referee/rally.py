"""Rally state, landing and in/out, and the referee stage (F14–F16, FR-14–FR-16).

In/out calls and the score are estimates: close calls are flagged as uncertain (no winner
is awarded) and the app always allows a manual correction. The call itself lives in
linecalls.py; each landing also becomes a LineCall in record.line_calls.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

from shuttlesense.schema import (
    ClipRecord,
    Landing,
    PlayerSide,
    Rally,
    RallyEvent,
    ScorePair,
)
from shuttlesense.stage import StageContext, StageSkipped
from shuttlesense.timing import scaled

STATIONARY_PX = 3.0
# stages.referee keys that count frames.
FRAME_KEYS = ("stationary_frames_end", "lost_frames_end")


@dataclass(frozen=True)
class Segment:
    start: int
    end: int
    closed: bool  # False when the clip ends mid-rally
    landing_frame: int | None  # where the shuttle came to rest, if seen


def _rest_after(
    visible: np.ndarray,
    xy: np.ndarray,
    frame: int,
    stop: int,
    cfg: dict[str, Any],
    unobserved: set[int],
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
        if i in unobserved:
            # No observation is neither a lost shuttle nor evidence of a stationary one.
            missing, rest_start = 0, None
            continue
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
    visible: np.ndarray,
    xy: np.ndarray,
    hits: list[int],
    cfg: dict[str, Any],
    *,
    unobserved: set[int] | None = None,
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
            rest = _rest_after(visible, xy, hits[k], stop, cfg, unobserved or set())
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
    point_m: np.ndarray, size: tuple[float, float], band_m: float
) -> tuple[bool, float]:
    """(in_court, confidence) against the singles rally lines with a fixed band."""
    from shuttlesense.court.lines import play_bounds
    from shuttlesense.referee.linecalls import call_landing

    call, _, confidence, _ = call_landing(point_m, play_bounds("singles", size), band_m)
    return call == "in", confidence


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


def build_events(record: ClipRecord) -> list[RallyEvent]:
    """The rally timeline (start, hits, landing, end, score) in frame order."""
    fps = record.fps or 1.0
    calls = {c.rally_index: c for c in record.line_calls}
    events: list[RallyEvent] = []

    def add(frame: int, kind: str, rally: int | None, **data: Any) -> None:
        events.append(RallyEvent(frame=frame, time_s=round(frame / fps, 3), type=kind,
                                 rally_index=rally, data=data))  # fmt: skip

    for r in record.rallies:
        add(r.start_frame, "rally_start", r.index)
    for h in record.hits:
        data = {"hitter": h.hitter} if h.hitter else {}
        add(h.frame, "hit", h.rally_index, hit_id=h.id, player=h.player, stroke=h.stroke, **data)
    for r in record.rallies:
        call = calls.get(r.index)
        if call is not None:
            add(call.frame, "landing", r.index, line_call_id=call.id, call=call.effective_call)
        add(r.end_frame, "rally_end", r.index, winner=r.winner)
        if r.score_after is not None:
            add(r.end_frame, "score", r.index, near=r.score_after.near, far=r.score_after.far)
    order = {"rally_start": 0, "hit": 1, "landing": 2, "rally_end": 3, "score": 4}
    events.sort(key=lambda e: (e.frame, order[e.type]))
    return events


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill rallies[], line_calls[], rally_events[], hits[].rally_index, rally_state, score."""
    from shuttlesense.analytics.stage import count_strokes
    from shuttlesense.court import image_to_court
    from shuttlesense.referee.linecalls import line_call_config, make_line_call
    from shuttlesense.referee.scoring import apply_rallies, flag_service, match_config
    from shuttlesense.tracking import track_arrays

    if not record.hits:
        raise StageSkipped("no hits, so no rallies")
    # Frame counts in the config are for 30 fps.
    cfg = scaled(ctx.stage_config("referee"), FRAME_KEYS, record.fps)
    xy, visible = track_arrays(record)
    segments = segment_rallies(
        visible,
        np.nan_to_num(xy),
        [h.frame for h in record.hits],
        cfg,
        unobserved=set(ctx.config.get("_unobserved_frames", ())),
    )

    size = record.court.court_size_m if record.court else None
    line_cfg = line_call_config(cfg)
    rallies, calls = [], []
    for index, seg in enumerate(segments):
        hits_in = [h for h in record.hits if seg.start <= h.frame <= seg.end]
        for h in hits_in:
            h.rally_index = index
        rally = Rally(index=index, start_frame=seg.start, end_frame=seg.end)
        point = None
        if seg.closed and seg.landing_frame is not None and record.court is not None:
            point = image_to_court(np.asarray(record.court.homography), xy[[seg.landing_frame]])[0]
        # A point near the homography's horizon maps to inf/NaN, which JSON cannot hold.
        if point is not None and np.isfinite(point).all():
            call = make_line_call(record, rally, seg.landing_frame, point, line_cfg)
            call.id = len(calls)
            calls.append(call)
            x_m, y_m = call.landing_xy
            rally.landing = Landing(
                x_m=x_m, y_m=y_m, in_court=call.call == "in", confidence=call.confidence
            )
        last = hits_in[-1].player if hits_in else None
        if size and seg.closed:
            rally.winner = rally_winner(rally.landing, last, size[1] / 2)
        rallies.append(rally)

    for f in record.frames:
        inside = any(r.start_frame <= f.frame <= r.end_frame for r in rallies)
        f.rally_state = "in_play" if inside else "between_rallies"
    record.rallies = rallies
    record.line_calls = calls
    count_strokes(record)
    start = ScorePair(**ctx.config.get("start_score", {}) or {})
    match = match_config(ctx.config)
    record.score = apply_rallies(record.rallies, start, **match)
    flag_service(record, start)
    record.rally_events = build_events(record)
    ctx.progress(1.0)
    return record
