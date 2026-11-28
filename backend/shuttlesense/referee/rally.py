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
# Pixel distances in the config are for 720p video and scale with the frame height.
REST_RADIUS_PX = 6.0  # a resting shuttle's detections stay this close to where it settled
MIN_APPROACH_PX = 15.0  # ...and it flew in from at least this far away
APPROACH_FRAMES = 10  # frames before the rest that must show that flight
MAX_MISSED_AT_REST = 2  # single missed detections while resting do not break the rest
# A shuttle lost as it falls and found lying where it fell (D46).
RELOCATE_PX = 40.0  # the rest is at most this far from the last point of the flight
RELOCATE_STILL_FRAMES = 6  # ...and stays put this long
RELOCATE_EXTRA_FRAMES = 15  # it must settle within lost_frames_end + this after the loss
FALLING_FRAMES = 8  # frames before the loss that must show the shuttle coming down
# A shuttle that settles before the clip ends (D48): nothing can follow the last frame, so a
# shorter rest than stationary_frames_end is enough to call it.
END_REST_FRAMES = 8
# A high shuttle above the frame (D62): lost for up to this long, it is back in play when it
# comes down into the frame within this distance of the top edge.
TOP_EXIT_FRAMES = 75
TOP_EXIT_PX = 40.0
# stages.referee keys that count frames.
FRAME_KEYS = (
    "stationary_frames_end",
    "lost_frames_end",
    "approach_frames",
    "relocate_still_frames",
    "relocate_extra_frames",
    "end_rest_frames",
    "top_exit_frames",
)
PIXEL_KEYS = ("rest_radius_px", "min_approach_px", "relocate_px", "top_exit_px")


def scaled_pixels(cfg: dict[str, Any], height: int | None) -> dict[str, Any]:
    """A copy of `cfg` with the 720p pixel distances converted to the video's height."""
    scale = (height or 720) / 720
    out = dict(cfg)
    defaults = {
        "rest_radius_px": REST_RADIUS_PX,
        "min_approach_px": MIN_APPROACH_PX,
        "relocate_px": RELOCATE_PX,
        "top_exit_px": TOP_EXIT_PX,
    }
    for key in PIXEL_KEYS:
        out[key] = float(out.get(key, defaults[key])) * scale
    return out


class _RestRun:
    """Consecutive detections of a shuttle at rest (D48).

    A detection belongs to the rest when it lies within `radius` of the rest's first
    detection (the D45 rule) or of the median of the rest so far. The median keeps a rest
    whose first detection was taken mid-bounce, or which jitters or slides a few pixels,
    from restarting again and again. A moving shuttle still breaks the run: the median lags
    behind it by more than the radius within a few frames.
    """

    def __init__(self, radius: float) -> None:
        self.radius = radius
        self.frames: list[int] = []
        self.points: list[np.ndarray] = []

    def reset(self) -> None:
        self.frames, self.points = [], []

    def add(self, frame: int, point: np.ndarray) -> None:
        """Add a detection; one that fits neither the start nor the median starts anew."""
        point = np.asarray(point, dtype=float)
        if self.points and not (
            np.linalg.norm(point - self.points[0]) <= self.radius
            or np.linalg.norm(point - self.centre()) <= self.radius
        ):
            self.reset()
        self.frames.append(frame)
        self.points.append(point)

    @property
    def start(self) -> int | None:
        return self.frames[0] if self.frames else None

    def centre(self) -> np.ndarray:
        return np.median(np.asarray(self.points), axis=0)

    @property
    def count(self) -> int:
        return len(self.points)


def _approached(
    visible: np.ndarray, xy: np.ndarray, rest: int, first: int, cfg: dict[str, Any]
) -> bool:
    """Whether the shuttle flew in before resting at frame `rest`.

    A real landing follows a flight, so some detection in the approach_frames before the
    rest lies min_approach_px or more away. A detection that never moved (a logo, a line,
    a shuttle lying off court the whole time) is not a landing (D45).
    """
    lookback = int(cfg.get("approach_frames", APPROACH_FRAMES))
    far = float(cfg.get("min_approach_px", MIN_APPROACH_PX))
    lo = max(first, rest - lookback)
    seen = visible[lo:rest].astype(bool)
    if not seen.any():
        return False
    return bool((np.linalg.norm(xy[lo:rest][seen] - xy[rest], axis=1) >= far).any())


def _fell_into(
    visible: np.ndarray,
    xy: np.ndarray,
    rest: int,
    first: int,
    cfg: dict[str, Any],
    unobserved: set[int],
) -> bool:
    """Whether the rest at `rest` follows a short gap in which the shuttle fell into it.

    The approach window only looks approach_frames back, so a shuttle missed for longer
    than that as it fell (but less than lost_frames_end, so the lost rule never ran) and
    then found lying still had no flight before its rest. It is a landing on the same
    terms as a shuttle lost for longer (D46): it was coming down when last seen and it lies
    within relocate_px of that point. A gap with unobserved frames proves nothing.
    """
    before = np.flatnonzero(visible[first:rest]) + first
    if not len(before) or rest - before[-1] <= 1:
        return False
    last = int(before[-1])
    if rest - last > int(cfg.get("lost_frames_end", 30)):
        return False
    if any(i in unobserved for i in range(last + 1, rest)):
        return False
    lookback = int(cfg.get("approach_frames", FALLING_FRAMES))
    seen = [j for j in range(max(first, last - lookback), last + 1) if visible[j]]
    if len(seen) < 3 or xy[seen[-1]][1] - xy[seen[0]][1] <= 0:
        return False
    near = float(cfg.get("relocate_px", RELOCATE_PX))
    return bool(np.linalg.norm(xy[rest] - xy[last]) <= near)


def _relocated_rest(
    visible: np.ndarray,
    xy: np.ndarray,
    last_visible: int,
    cfg: dict[str, Any],
    unobserved: set[int],
) -> tuple[int, np.ndarray] | None:
    """(landing frame, image point) of a shuttle lost as it fell and found lying where it fell.

    Small, fast and often hidden by a player or the net, a falling shuttle is commonly
    missed for a second and found again on the floor. That is a landing when (D46):
    the shuttle was coming down (image y rising) when it was lost; it is found again and
    stays within rest_radius_px for relocate_still_frames, settling no later than
    lost_frames_end + relocate_extra_frames after the loss, so a live session knows it
    before it closes the rally; and it lies within relocate_px of the last flight point.
    Anything else (an unobserved frame, a rest somewhere else) gives no landing. Hits after
    the loss are not a limit: a hit detected on a shuttle lying still is not a stroke.
    """
    lost = int(cfg.get("lost_frames_end", 30))
    still = int(cfg.get("relocate_still_frames", RELOCATE_STILL_FRAMES))
    extra = int(cfg.get("relocate_extra_frames", RELOCATE_EXTRA_FRAMES))
    radius = float(cfg.get("rest_radius_px", STATIONARY_PX))
    near = float(cfg.get("relocate_px", RELOCATE_PX))
    lookback = int(cfg.get("approach_frames", FALLING_FRAMES))
    seen = [j for j in range(max(0, last_visible - lookback), last_visible + 1) if visible[j]]
    if len(seen) < 3 or xy[seen[-1]][1] - xy[seen[0]][1] <= 0:
        return None  # not seen coming down: it may have flown out of the frame
    rest = _RestRun(radius)
    missing = 0
    for i in range(last_visible + 1, min(len(visible), last_visible + lost + extra + 1)):
        if i in unobserved:
            return None
        if not visible[i]:
            missing += 1
            if missing > MAX_MISSED_AT_REST:
                rest.reset()
            continue
        missing = 0
        rest.add(i, xy[i])
        if rest.count >= still:
            close = np.linalg.norm(rest.centre() - xy[last_visible]) <= near
            return (int(rest.frames[0]), rest.centre()) if close else None
    return None


def _back_from_above(
    visible: np.ndarray,
    xy: np.ndarray,
    last_visible: int,
    now: int,
    stop: int,
    cfg: dict[str, Any],
    unobserved: set[int],
) -> int | None:
    """The frame a shuttle lost from view comes back down into the top of the frame, if it
    does within top_exit_frames of the loss (D62).

    A high clear or lift can stay above the frame for longer than lost_frames_end. When it
    reappears at the top edge (within top_exit_px) and comes down, it never left play: the
    rally goes on. An unobserved frame before it proves nothing, so it gives None.
    """
    window = int(cfg.get("top_exit_frames", TOP_EXIT_FRAMES))
    top = float(cfg.get("top_exit_px", TOP_EXIT_PX))
    end = min(stop, len(visible), last_visible + window + 1)
    for j in range(now + 1, end):
        if j in unobserved:
            return None
        if not visible[j]:
            continue
        if xy[j][1] > top:
            return None  # found somewhere else: not the same flight coming back
        later = [k for k in range(j + 1, min(end, j + 5)) if visible[k]]
        return j if later and xy[later[-1]][1] > xy[j][1] else None
    return None


@dataclass(frozen=True)
class Segment:
    start: int
    end: int
    closed: bool  # False when the clip ends mid-rally
    landing_frame: int | None  # where the shuttle came to rest, if seen
    # Where it lies in the image: the median of its resting detections, steadier than the
    # first resting frame, which may be taken mid-bounce (D48).
    landing_px: tuple[float, float] | None = None


def _rest_after(
    visible: np.ndarray,
    xy: np.ndarray,
    frame: int,
    stop: int,
    cfg: dict[str, Any],
    unobserved: set[int],
) -> tuple[int, int | None, np.ndarray | None] | None:
    """First rally end in [frame, stop): (end frame, landing frame, landing image point) or
    None if play goes on.

    End rules: the shuttle stays invisible for lost_frames_end frames (end = last visible
    frame, landing unknown unless it was resting), or its detections stay within
    rest_radius_px of where it settled (their median, _RestRun) for stationary_frames_end
    frames (end = landing = first resting frame). The radius, not a per-frame step,
    absorbs tracker jitter, and a missed detection or two while resting does not restart
    the count. A lost shuttle gives no landing call (it may have left the frame, so the
    user decides that rally) unless it is found lying where it fell (_relocated_rest). A
    rest that did not follow a flight (_approached) also ends the rally without a landing.
    """
    lost = int(cfg.get("lost_frames_end", 30))
    still = int(cfg.get("stationary_frames_end", 20))
    radius = float(cfg.get("rest_radius_px", STATIONARY_PX))
    last_visible, missing = frame, 0
    resume: int | None = None  # the shuttle comes back down into the frame here (D62)
    rest = _RestRun(radius)
    for i in range(frame, stop):
        if i in unobserved:
            # No observation is neither a lost shuttle nor evidence of a stationary one.
            missing = 0
            rest.reset()
            continue
        if not visible[i]:
            missing += 1
            if missing > MAX_MISSED_AT_REST:
                rest.reset()
            if missing >= lost and resume is None:
                resume = _back_from_above(visible, xy, last_visible, i, stop, cfg, unobserved)
                if resume is None:
                    found = _relocated_rest(visible, xy, last_visible, cfg, unobserved)
                    return (last_visible, *found) if found else (last_visible, None, None)
            continue
        missing, resume = 0, None
        last_visible = i
        rest.add(i, xy[i])
        if rest.count >= still:
            rest_start = rest.start
            assert rest_start is not None
            if _approached(visible, xy, rest_start, frame, cfg) or _fell_into(
                visible, xy, rest_start, frame, cfg, unobserved
            ):
                return rest_start, rest_start, rest.centre()
            return rest_start, None, None
    return None


HELD_BOX_SHARE = 0.6  # a rest in the top 60 % of a player's box is in a hand, not on the floor
HELD_WRIST_SHARE = 0.25  # ...and, when the wrists are seen, this close to one (x box height)
WRISTS = (9, 10)  # COCO left and right wrist
MIN_WRIST_SCORE = 0.3


def held_by_player(record: ClipRecord, frame: int, px: np.ndarray) -> bool:
    """Whether the resting shuttle at image point `px` is in a player's hand.

    A shuttle held before the next serve, or caught, is still but off the floor, and the
    court homography only holds on the floor: its projection would be a bogus landing. It
    sits high in the player's box. A player's box also covers the floor behind them in the
    image, though: a player at the net hides the floor just past it, where net shots land.
    So when the player's wrists are seen, the shuttle must also be near one (D48); with no
    wrist seen, high in the box is enough, as before.
    """
    if not 0 <= frame < len(record.frames):
        return False
    x, y = float(px[0]), float(px[1])
    for player in record.frames[frame].players.slots().values():
        if player is None:
            continue
        bx, by, bw, bh = player.bbox
        if not (bx <= x <= bx + bw and by <= y <= by + HELD_BOX_SHARE * bh):
            continue
        wrists = [
            (kx, ky)
            for i, (kx, ky, score) in enumerate(player.keypoints)
            if i in WRISTS and score >= MIN_WRIST_SCORE
        ]
        if not wrists:
            return True
        if min(np.hypot(x - kx, y - ky) for kx, ky in wrists) <= HELD_WRIST_SHARE * bh:
            return True
    return False


def _settled_at_end(
    visible: np.ndarray,
    xy: np.ndarray,
    frame: int,
    n: int,
    cfg: dict[str, Any],
    unobserved: set[int],
) -> tuple[int, np.ndarray] | None:
    """(landing frame, image point) when the last rally's shuttle settles before the clip ends.

    stationary_frames_end (20 frames) rules out a rest followed by another hit, but a clip,
    or a live session stopped, a moment after the shuttle came down has nothing after it, so
    the last rally stayed open and nobody scored (D48). Here a rest of end_rest_frames
    observations is enough when it follows a flight (_approached, _fell_into), and every
    later detection to the end of the clip stays within relocate_px of it. A rest the shuttle
    leaves was not a landing; any unobserved frame after the hit gives nothing.
    """
    need = int(cfg.get("end_rest_frames", END_REST_FRAMES))
    radius = float(cfg.get("rest_radius_px", STATIONARY_PX))
    near = float(cfg.get("relocate_px", RELOCATE_PX))
    if any(i in unobserved for i in range(frame, n)):
        return None
    rest = _RestRun(radius)
    missing = 0
    for i in range(frame, n):
        if not visible[i]:
            missing += 1
            if missing > MAX_MISSED_AT_REST:
                rest.reset()
            continue
        missing = 0
        rest.add(i, xy[i])
        if rest.count < need:
            continue
        start = rest.frames[0]
        if not (
            _approached(visible, xy, start, frame, cfg)
            or _fell_into(visible, xy, start, frame, cfg, unobserved)
        ):
            return None  # a detection that never moved
        centre = rest.centre()
        later = [j for j in range(i + 1, n) if visible[j]]
        if all(np.linalg.norm(xy[j] - centre) <= near for j in later):
            return start, centre
        rest.reset()  # it moved on: not where the rally ended
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
    shuttle is lost or rests on the floor after its last hit. The last rally also ends where
    the shuttle settled before the clip ended (_settled_at_end); one still going at the end
    of the clip is left open.
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
                end, landing, px = rest
                spot = None if px is None else (float(px[0]), float(px[1]))
                segments.append(Segment(start, end, True, landing, spot))
                k += 1
                break
            if k + 1 >= len(hits):
                settled = _settled_at_end(visible, xy, hits[k], n, cfg, unobserved or set())
                if settled is not None:
                    at, px = settled
                    segments.append(Segment(start, at, True, at, (float(px[0]), float(px[1]))))
                else:
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
    landing: Landing | None,
    last_hitter: PlayerSide | None,
    net_y: float,
    *,
    check_side: bool = False,
) -> PlayerSide | None:
    """In: the player on whose half it landed loses. Out: the last hitter loses.

    Uncertain calls (confidence < 0.5) award nobody; the user confirms them in the app.
    With check_side (automated calls), an OUT must also agree with where it landed: a shot
    out on one side's half was hit by the other side, so when the last detected hitter is
    on the half it landed on (a missed hit, or a mishit) nobody is awarded (D45). A
    referee's own call (override) skips this check.
    """
    if landing is None or landing.confidence < 0.5:
        return None
    if landing.in_court:
        return "far" if landing.y_m < net_y else "near"
    if last_hitter is None:
        return None
    if check_side and ("far" if landing.y_m >= net_y else "near") == last_hitter:
        return None
    return "far" if last_hitter == "near" else "near"


# Next-serve evidence (D47). BWF Law 7: the side that wins a rally scores and serves the
# next one, so a serve seen after a rally says who won it. Defaults for
# stages.referee.serve_inference; times are in seconds, so they need no fps scaling.
SERVE_DEFAULTS: dict[str, Any] = {
    "enabled": True,
    "min_confidence": 0.6,  # the stroke model's confidence that the first hit is a serve
    # A lift that leaves the frame is back within about 1.5 s, so a shorter pause before a
    # "serve" is more likely the same rally split in two than a new rally.
    "min_pause_s": 2.0,
    # Game intervals (60 s at 11 in the deciding game, 120 s between games) can come with a
    # change of ends, which would put the winner on the other side of the image.
    "max_pause_s": 30.0,
    "position_margin_m": 0.6,  # tolerance on the server's feet when checking where they stand
}


def serve_config(cfg: dict[str, Any] | None) -> dict[str, Any]:
    """stages.referee.serve_inference merged over the defaults."""
    return {**SERVE_DEFAULTS, **((cfg or {}).get("serve_inference") or {})}


def rally_hits(record: ClipRecord, rally: Rally) -> list[Any]:
    """The rally's hits in frame order (by rally_index, else by its frames)."""
    hits = [h for h in record.hits if h.rally_index == rally.index] or [
        h for h in record.hits if rally.start_frame <= h.frame <= rally.end_frame
    ]
    return sorted(hits, key=lambda h: h.frame)


def _serving_position(record: ClipRecord, serve: Any, margin: float) -> bool:
    """Whether the server stands where a server can: on their own half, between the short
    service line and the baseline, within the doubles sidelines (lines widened by margin).
    An unknown position does not count against the serve."""
    from shuttlesense.court.lines import DOUBLES_SIDE_ALLEY_M, SHORT_SERVICE_FROM_NET_M
    from shuttlesense.schema import COURT_SIZE_M

    if not 0 <= serve.frame < len(record.frames):
        return True
    pos = record.frames[serve.frame].court_positions
    xy = getattr(pos, serve.player_attr, None) if pos is not None else None
    if xy is None or not np.isfinite(xy).all():
        return True
    w, length = record.court.court_size_m if record.court else COURT_SIZE_M
    x, y = float(xy[0]), float(xy[1])
    if not -DOUBLES_SIDE_ALLEY_M - margin <= x <= w + DOUBLES_SIDE_ALLEY_M + margin:
        return False
    short = length / 2 - SHORT_SERVICE_FROM_NET_M
    if serve.player == "near":
        return -margin <= y <= short + margin
    return length - short - margin <= y <= length + margin


def next_serve_side(
    record: ClipRecord, rally: Rally, next_rally: Rally | None, cfg: dict[str, Any] | None
) -> PlayerSide | None:
    """The side that served the rally after `rally`, when that serve is clear (D47).

    Only a serve the referee can stand behind counts: the next rally's first hit is
    classified a serve with min_confidence, it comes min_pause_s to max_pause_s after this
    rally ended, the server stands in a serving position when their feet are located, and
    in doubles the credited partner is on the serving side. Anything else gives None.
    """
    sc = serve_config(cfg)
    if not sc["enabled"] or next_rally is None or next_rally.index != rally.index + 1:
        return None
    hits = rally_hits(record, next_rally)
    if not hits:
        return None
    serve = hits[0]
    if serve.stroke != "serve" or (serve.confidence or 0.0) < float(sc["min_confidence"]):
        return None
    pause_s = (serve.frame - rally.end_frame) / (record.fps or 30.0)
    if not float(sc["min_pause_s"]) <= pause_s <= float(sc["max_pause_s"]):
        return None
    if serve.hitter is not None and not serve.hitter.startswith(serve.player):
        return None
    if not _serving_position(record, serve, float(sc["position_margin_m"])):
        return None
    return serve.player


def landing_winner(record: ClipRecord, rally: Rally) -> PlayerSide | None:
    """The automated winner from the rally's landing alone (D45 guards included)."""
    from shuttlesense.schema import COURT_SIZE_M

    size = record.court.court_size_m if record.court else COURT_SIZE_M
    hits = rally_hits(record, rally)
    last = hits[-1].player if hits else None
    return rally_winner(rally.landing, last, size[1] / 2, check_side=True)


def decide_winner(
    record: ClipRecord, rally: Rally, next_rally: Rally | None, cfg: dict[str, Any] | None
) -> PlayerSide | None:
    """The automated winner from the landing and the next serve together (D47).

    The landing decides when it can. A rally it cannot decide (no landing seen, lost, held,
    uncertain, implausible) is decided by a clear next serve. When both are there and
    disagree, one of them is wrong (a misplaced landing, a missed hit, a serve credited to
    the wrong side), so nobody is awarded and the user decides: a wrong point is worse
    than an unscored one (D45).
    """
    by_landing = landing_winner(record, rally)
    by_serve = next_serve_side(record, rally, next_rally, cfg)
    if by_landing is None or by_serve is None:
        return by_landing or by_serve
    return by_landing if by_landing == by_serve else None


def referee_review(record: ClipRecord, rally: Rally) -> str | None:
    """Why the user should look at how this rally was decided, from the record alone (D47).

    A rally scored from the next serve, or withheld because its landing and the next serve
    disagree, says so. A rally the user decided (override or winner correction) does not.
    """
    if record.court is None:
        return None
    corrections = record.score.corrections if record.score is not None else []
    if any(c.kind == "winner" and c.rally_index == rally.index for c in corrections):
        return None
    if any(c.rally_index == rally.index and c.override is not None for c in record.line_calls):
        return None
    following = next((r for r in record.rallies if r.index == rally.index + 1), None)
    by_serve = next_serve_side(record, rally, following, None)
    if by_serve is None:
        return None
    by_landing = landing_winner(record, rally)
    if by_landing is None and rally.winner == by_serve:
        return f"Scored for {by_serve} from the next serve: no landing call decided it"
    if by_landing is not None and by_landing != by_serve and rally.winner is None:
        return f"The landing gives the rally to {by_landing}, but {by_serve} served next"
    return None


def apply_serve_evidence(record: ClipRecord, cfg: dict[str, Any] | None) -> None:
    """Set every rally's automated winner from its landing and the next serve.

    The winner is recomputed from the record each time, never read from rally.winner, so
    this can run again as rallies are added (live). The user's line-call overrides and
    score corrections are applied after it by their callers and still win.
    """
    if record.court is None:
        return  # no court, no automated decisions (the stage needs one)
    rallies = sorted(record.rallies, key=lambda r: r.index)
    for rally, following in zip(rallies, [*rallies[1:], None], strict=True):
        rally.winner = decide_winner(record, rally, following, cfg)


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
    from shuttlesense.config import court_type
    from shuttlesense.court import image_to_court
    from shuttlesense.referee.linecalls import line_call_config, make_line_call
    from shuttlesense.referee.scoring import apply_rallies, flag_service, match_config
    from shuttlesense.tracking import track_arrays

    if not record.hits:
        raise StageSkipped("no hits, so no rallies")
    # Frame counts in the config are for 30 fps, pixel distances for 720p.
    cfg = scaled_pixels(scaled(ctx.stage_config("referee"), FRAME_KEYS, record.fps), record.height)
    xy, visible = track_arrays(record)
    for i in record._estimated_shuttle_frames:
        visible[i] = 0
    segments = segment_rallies(
        visible,
        np.nan_to_num(xy),
        [h.frame for h in record.hits],
        cfg,
        unobserved=set(ctx.config.get("_unobserved_frames", ())),
    )

    size = record.court.court_size_m if record.court else None
    # Singles or doubles lines follow the match (the job's court), whatever line_call says.
    line_cfg = {**line_call_config(cfg), "court": court_type(ctx.config)}
    rallies, calls = [], []
    for index, seg in enumerate(segments):
        hits_in = [h for h in record.hits if seg.start <= h.frame <= seg.end]
        for h in hits_in:
            h.rally_index = index
        rally = Rally(index=index, start_frame=seg.start, end_frame=seg.end)
        point = None
        landing = seg.landing_frame if seg.closed else None
        spot = np.asarray(seg.landing_px if seg.landing_px is not None else xy[landing or 0])
        if landing is not None and held_by_player(record, landing, spot):
            landing = None  # in a hand, not on the floor: the user decides the rally
        if landing is not None and record.court is not None:
            point = image_to_court(np.asarray(record.court.homography), spot[None, :])[0]
        # A point near the homography's horizon maps to inf/NaN, which JSON cannot hold.
        if landing is not None and point is not None and np.isfinite(point).all():
            call = make_line_call(record, rally, landing, point, line_cfg)
            call.id = len(calls)
            calls.append(call)
            x_m, y_m = call.landing_xy
            rally.landing = Landing(
                x_m=x_m, y_m=y_m, in_court=call.call == "in", confidence=call.confidence
            )
        rallies.append(rally)

    for f in record.frames:
        inside = any(r.start_frame <= f.frame <= r.end_frame for r in rallies)
        f.rally_state = "in_play" if inside else "between_rallies"
    record.rallies = rallies
    record.line_calls = calls
    if size:
        # The landing decides each rally it can; the next serve decides the rest (D47).
        apply_serve_evidence(record, cfg)
    count_strokes(record)
    start = ScorePair(**ctx.config.get("start_score", {}) or {})
    match = match_config(ctx.config)
    record.score = apply_rallies(record.rallies, start, **match)
    flag_service(record, start)
    record.rally_events = build_events(record)
    ctx.progress(1.0)
    return record
