"""Automated in/out line calls (F20, FR-20).

A call projects the shuttle at its landing frame onto the court plane and measures the
signed distance to the nearest relevant line (positive inside). One camera cannot place a
landing to the centimetre, so every call carries an uncertainty band built from the
calibration error and the tracking error at that spot of the image: a landing closer to a
line than the band is UNCERTAIN and waits for the user. These are automated calls with a
stated confidence, never official ones.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np
from pydantic import BaseModel, TypeAdapter

from shuttlesense.atomic import atomic_write_text
from shuttlesense.court.lines import Bounds, play_bounds, service_bounds
from shuttlesense.schema import (
    COURT_SIZE_M,
    Call,
    ClipRecord,
    CourtType,
    LineCall,
    LineCallOverride,
    Rally,
)

# Defaults for stages.referee.line_call in configs/pipeline.yaml.
DEFAULTS: dict[str, Any] = {
    "court": "singles",
    "homography_err_m": 0.05,  # corner taps a few pixels off move the lines this much
    "tracking_err_px": 4.0,  # TrackNetV3 is counted correct within 4 px
    "min_band_m": 0.05,
    # BWF asks for 2 m of clear floor around the court: a rest farther out than this is
    # more likely a false detection (stands, boards) than a shuttle hit out (D45).
    "max_out_m": 2.0,
}

OVERRIDES_FILE = "line_call_overrides.json"


class LineCallOverrideIn(BaseModel):
    """One user decision, keyed by rally so it survives a re-run that renumbers calls."""

    rally_index: int
    call: Call
    at: datetime


_OVERRIDES = TypeAdapter(list[LineCallOverrideIn])


def line_call_config(cfg: dict[str, Any] | None) -> dict[str, Any]:
    """stages.referee.line_call merged over the defaults."""
    return {**DEFAULTS, **((cfg or {}).get("line_call") or {})}


def signed_margin(point_m: Sequence[float], bounds: Bounds) -> float:
    """Distance in meters from the point to the area's edge; positive inside (lines are in)."""
    x, y = float(point_m[0]), float(point_m[1])
    x0, x1, y0, y1 = bounds
    if x0 <= x <= x1 and y0 <= y <= y1:
        return min(x - x0, x1 - x, y - y0, y1 - y)
    dx = max(x0 - x, 0.0, x - x1)
    dy = max(y0 - y, 0.0, y - y1)
    return -float(np.hypot(dx, dy))


def _tracking_extent(h: np.ndarray, point_m: Sequence[float], radius: float) -> np.ndarray:
    """Bound the court x/y displacements over a disk of image tracking error."""
    h = np.asarray(h, dtype=float)
    point = np.asarray(point_m, dtype=float)
    try:
        image = np.linalg.solve(h, [*point, 1.0])
    except (ValueError, np.linalg.LinAlgError):
        return np.full(2, np.inf)
    if not np.isfinite(image).all() or image[2] == 0:
        return np.full(2, np.inf)
    # In homogeneous coordinates a pixel perturbation changes both numerator and
    # denominator. If the disk reaches the horizon there is no finite error bound.
    denominator = abs(1 / image[2]) - radius * np.linalg.norm(h[2, :2])
    if denominator <= 0 or not np.isfinite(denominator):
        return np.full(2, np.inf)
    slopes = h[:2, :2] - point[:, None] * h[2, :2]
    return radius * np.linalg.norm(slopes, axis=1) / denominator


def meters_per_pixel(h: np.ndarray, point_m: Sequence[float]) -> float:
    """Largest court-axis displacement bound for one pixel at this landing."""
    return float(max(_tracking_extent(h, point_m, 1.0)))


def _axis_bands(cfg, h, point_m) -> np.ndarray:
    tracking = np.zeros(2)
    if h is not None and point_m is not None:
        tracking = _tracking_extent(h, point_m, float(cfg["tracking_err_px"]))
    return np.maximum(cfg["min_band_m"], np.hypot(cfg["homography_err_m"], tracking))


def uncertainty_band(
    cfg: dict[str, Any], h: np.ndarray | None = None, point_m: Sequence[float] | None = None
) -> float:
    """Conservative scalar band for callers that do not specify a line direction."""
    return float(max(_axis_bands(cfg, h, point_m)))


def call_landing(
    point_m: Sequence[float], bounds: Bounds, band_m: float
) -> tuple[Call, float, float, bool]:
    """(call, margin_m, confidence, uncertain) for one landing.

    Confidence is 0.5 at the edge of the band and 1 at twice the band, so `uncertain` and
    `confidence < 0.5` always agree (the app and the scorer rely on that).
    """
    margin = signed_margin(point_m, bounds)
    call: Call = "in" if margin >= 0 else "out"
    if not np.isfinite(band_m):
        return call, margin, 0.0, True
    confidence = 1.0 if band_m <= 0 else min(1.0, 0.5 * abs(margin) / band_m)
    uncertain = abs(margin) < band_m
    rounded = round(confidence, 3)
    if uncertain and rounded >= 0.5:  # just inside the band must not round up to certain
        rounded = 0.499
    return call, margin, rounded, uncertain


def _boundary_call(point_m, bounds, bands) -> tuple[Call, float, float, bool]:
    margin = signed_margin(point_m, bounds)
    call = "in" if margin >= 0 else "out"
    if not np.isfinite(bands).all():
        return call, margin, 0.0, True
    x, y = point_m
    left, right, near, far = bounds
    # Inside requires clearance from every edge. Outside needs only one edge
    # that the entire error region is beyond. Keep the displayed margin in metres.
    clearances = (min(x - left, right - x), min(y - near, far - y))
    ratios = [
        distance / band if band > 0 else (np.inf if distance >= 0 else -np.inf)
        for distance, band in zip(clearances, bands, strict=True)
    ]
    ratio = abs(min(ratios))
    uncertain = ratio < 1
    confidence = round(min(1.0, 0.5 * ratio), 3)
    return call, margin, min(confidence, 0.499) if uncertain else confidence, uncertain


def nearest_line(point_m: Sequence[float], bounds: Bounds, size: Sequence[float]) -> str:
    """Plain name of the area's edge nearest the point: side line, back line or service
    line (the short or doubles long service line of a service box)."""
    x, y = float(point_m[0]), float(point_m[1])
    x0, x1, y0, y1 = bounds
    across = min(abs(x - x0), abs(x - x1))
    end = y0 if abs(y - y0) <= abs(y - y1) else y1
    if across < abs(y - end):
        return "side line"
    return "back line" if min(abs(end), abs(end - float(size[1]))) < 1e-6 else "service line"


def implausible(
    point_m: Sequence[float],
    margin: float,
    size: Sequence[float],
    band_m: float,
    cfg: dict[str, Any],
) -> bool:
    """Whether a landing cannot be trusted to decide a rally, whatever its margin (D45).

    A rest far beyond the court surround is more likely a false detection than a shot, and
    a landing within the band of the net leaves the half (so the winner) unknown.
    """
    if margin < -float(cfg.get("max_out_m", DEFAULTS["max_out_m"])):
        return True
    return abs(float(point_m[1]) - size[1] / 2) < band_m


def candidate_bounds(
    record: ClipRecord, rally: Rally, court: CourtType, cfg: dict[str, Any]
) -> tuple[Bounds, ...]:
    """Plausible receiving areas for the last stroke of the rally."""
    size = record.court.court_size_m if record.court else COURT_SIZE_M
    hits = [h for h in record.hits if h.rally_index == rally.index] or [
        h for h in record.hits if rally.start_frame <= h.frame <= rally.end_frame
    ]
    if len(hits) == 1 and hits[0].stroke == "serve":
        serve = hits[0]
        frame = record.frames[serve.frame] if serve.frame < len(record.frames) else None
        pos = frame.court_positions if frame else None
        slots = (serve.player_attr,)
        if court == "doubles" and serve.hitter is None:
            slots = (serve.player, f"{serve.player}_2")
        h = np.asarray(record.court.homography) if record.court else None
        boxes = []
        for slot in slots:
            server = getattr(pos, slot, None)
            if (
                server is None
                or not np.isfinite(server).all()
                or abs(server[0] - size[0] / 2) <= _axis_bands(cfg, h, server)[0]
            ):
                # Even one unlocated candidate could have served from either side.
                return tuple(service_bounds(serve.player, x, court, size) for x in (0.0, size[0]))
            boxes.append(service_bounds(serve.player, server[0], court, size))
        return tuple(dict.fromkeys(boxes))
    return (play_bounds(court, size),)


def make_line_call(
    record: ClipRecord,
    rally: Rally,
    frame: int,
    point_m: Sequence[float],
    cfg: dict[str, Any],
    *,
    extra_band_m: float = 0.0,
) -> LineCall:
    """The call for one landing. `extra_band_m` widens the band on both axes: how far a
    shuttle still settling when the clip ended may yet have moved (D60)."""
    court: CourtType = cfg["court"]
    areas = candidate_bounds(record, rally, court, cfg)
    h = np.asarray(record.court.homography) if record.court else None
    bands = np.hypot(_axis_bands(cfg, h, point_m), extra_band_m)
    candidates = [_boundary_call(point_m, bounds, bands) for bounds in areas]
    # Use the most inclusive box for the provisional call and its displayed margin.
    call, margin, confidence, uncertain = max(candidates, key=lambda result: result[1])
    disagreement = any(result[0] != call or result[3] for result in candidates)
    size = record.court.court_size_m if record.court else COURT_SIZE_M
    court_margin = signed_margin(point_m, play_bounds(court, size))
    if disagreement or implausible(point_m, court_margin, size, bands[1], cfg):
        confidence, uncertain = min(confidence, 0.499), True
    return LineCall(
        id=0,
        rally_index=rally.index,
        frame=frame,
        time_s=round(frame / record.fps, 3) if record.fps else 0.0,
        call=call,
        landing_xy=(round(float(point_m[0]), 3), round(float(point_m[1]), 3)),
        margin_cm=round(margin * 100, 1),
        confidence=confidence,
        uncertain=uncertain,
        court=court,
    )


def derive_from_rallies(record: ClipRecord, cfg: dict[str, Any] | None = None) -> list[LineCall]:
    """Line calls for the rallies' landings (used to upgrade 1.0 records)."""
    cfg = line_call_config(cfg)
    calls = [
        make_line_call(record, r, r.end_frame, (r.landing.x_m, r.landing.y_m), cfg)
        for r in record.rallies
        if r.landing is not None
    ]
    for i, c in enumerate(calls):
        c.id = i
    return calls


def load_overrides(out_dir: Path) -> list[LineCallOverrideIn]:
    path = out_dir / OVERRIDES_FILE
    if not path.exists():
        return []
    return _OVERRIDES.validate_json(path.read_text(encoding="utf-8"))


def save_overrides(out_dir: Path, overrides: Sequence[LineCallOverrideIn]) -> None:
    data = _OVERRIDES.dump_python(list(overrides), mode="json")
    atomic_write_text(out_dir / OVERRIDES_FILE, json.dumps(data, indent=2))


def apply_overrides(record: ClipRecord, overrides: Sequence[LineCallOverrideIn]) -> None:
    """Put the user's calls on the line calls and landings and re-decide the rally winners.

    A confirmed or overridden call is certain, so its rally gets a winner again. Score
    corrections (scoring.apply_corrections) run after this; a winner correction older than
    the rally's override is skipped there, so the newest decision wins (D32).
    """
    from shuttlesense.referee.rally import rally_hits, rally_winner
    from shuttlesense.referee.strikes import final_striker

    latest = {o.rally_index: o for o in sorted(overrides, key=lambda o: o.at)}
    rallies = {r.index: r for r in record.rallies}
    size = record.court.court_size_m if record.court else COURT_SIZE_M
    for call in record.line_calls:
        o = latest.get(call.rally_index)
        if o is None:
            continue
        call.override = LineCallOverride(call=o.call, at=o.at)
        rally = rallies.get(call.rally_index)
        if rally is None or rally.landing is None:
            continue
        rally.landing.in_court = o.call == "in"
        rally.landing.confidence = 1.0
        hits = rally_hits(record, rally)
        # The user settled IN or OUT; who touched it last still comes from the track, so a
        # return the hit detector missed is credited like an automated call (D61).
        striker = final_striker(record, hits, call.frame) if hits else None
        last = striker.side if striker is not None and striker.side is not None else None
        last = last or (hits[-1].player if hits else None)
        rally.winner = rally_winner(rally.landing, last, size[1] / 2)


def clear_override(record: ClipRecord, rally_index: int) -> None:
    """Put a rally's call back to the automated one after its override is taken back.

    The winner goes back to the automated decision, landing and next serve together (D47),
    with the default serve settings since the record does not keep the job's config.
    """
    from shuttlesense.referee.rally import decide_winner

    rallies = {r.index: r for r in record.rallies}
    for call in record.line_calls:
        if call.rally_index != rally_index or call.override is None:
            continue
        call.override = None
        rally = rallies.get(rally_index)
        if rally is None or rally.landing is None:
            continue
        rally.landing.in_court = call.call == "in"
        rally.landing.confidence = call.confidence
        rally.winner = decide_winner(record, rally, rallies.get(rally_index + 1), None)
