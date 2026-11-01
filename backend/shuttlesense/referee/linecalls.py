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


def meters_per_pixel(h: np.ndarray, point_m: Sequence[float]) -> float:
    """How far one image pixel moves a point on the court plane, near `point_m`."""
    from shuttlesense.court import court_to_image, image_to_court

    px = court_to_image(h, np.array([point_m], dtype=float))[0]
    probes = np.array([px, px + (1.0, 0.0), px + (0.0, 1.0)])
    court = image_to_court(h, probes)
    if not np.isfinite(court).all():
        return float("inf")
    return float((np.linalg.norm(court[1] - court[0]) + np.linalg.norm(court[2] - court[0])) / 2)


def uncertainty_band(
    cfg: dict[str, Any], h: np.ndarray | None = None, point_m: Sequence[float] | None = None
) -> float:
    """Half-width in meters of the band around a line where a call is uncertain.

    Calibration and tracking errors are independent, so they add in quadrature. Tracking
    error is in pixels and grows in meters toward the far baseline, where a pixel covers
    more court.
    """
    tracking_m = 0.0
    if h is not None and point_m is not None:
        tracking_m = float(cfg["tracking_err_px"]) * meters_per_pixel(h, point_m)
    band = float(np.hypot(float(cfg["homography_err_m"]), tracking_m))
    return max(float(cfg["min_band_m"]), band)


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


def bounds_for(record: ClipRecord, rally: Rally, court: CourtType) -> tuple[Bounds, bool]:
    """(area the rally's last shot had to land in, whether that is a service court)."""
    size = record.court.court_size_m if record.court else COURT_SIZE_M
    hits = [h for h in record.hits if h.rally_index == rally.index] or [
        h for h in record.hits if rally.start_frame <= h.frame <= rally.end_frame
    ]
    if len(hits) == 1 and hits[0].stroke == "serve":
        serve = hits[0]
        frame = record.frames[serve.frame] if serve.frame < len(record.frames) else None
        pos = frame.court_positions if frame else None
        server = getattr(pos, serve.player, None) if pos else None
        if server is not None:
            return service_bounds(serve.player, server[0], court, size), True
    return play_bounds(court, size), False


def make_line_call(
    record: ClipRecord, rally: Rally, frame: int, point_m: Sequence[float], cfg: dict[str, Any]
) -> LineCall:
    court: CourtType = cfg["court"]
    bounds, _ = bounds_for(record, rally, court)
    h = np.asarray(record.court.homography) if record.court else None
    band = uncertainty_band(cfg, h, point_m)
    call, margin, confidence, uncertain = call_landing(point_m, bounds, band)
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
    corrections (scoring.apply_corrections) still win over this, since they come later.
    """
    from shuttlesense.referee.rally import rally_winner

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
        hits = [h for h in record.hits if h.rally_index == rally.index]
        rally.winner = rally_winner(rally.landing, hits[-1].player if hits else None, size[1] / 2)
