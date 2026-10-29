"""Analytics stage: court positions, speeds, counts and summary (F10–F13)."""

from __future__ import annotations

import logging

import numpy as np

from shuttlesense.analytics.export import build_summary
from shuttlesense.analytics.positions import apply_positions, project_positions
from shuttlesense.analytics.speed import hit_speed, speeds_kmh
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext

log = logging.getLogger(__name__)


def count_strokes(record: ClipRecord) -> ClipRecord:
    """rallies[].stroke_count from the hits inside each rally's frame span."""
    for rally in record.rallies:
        rally.stroke_count = sum(
            1 for h in record.hits if rally.start_frame <= h.frame <= rally.end_frame
        )
    return record


def strokes_so_far(record: ClipRecord, frame: int) -> int:
    """Strokes up to `frame` in the rally containing it (whole clip without rallies)."""
    start = 0
    for rally in record.rallies:
        if rally.start_frame <= frame:
            start = rally.start_frame
    return sum(1 for h in record.hits if start <= h.frame <= frame)


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill court_positions, per-frame and per-hit speeds, rally stroke counts and summary."""
    cfg = ctx.stage_config("analytics")
    positions = project_positions(record, smooth=cfg.get("position_smoothing", 5))
    apply_positions(record, positions)

    if record.court is not None:
        kmh = speeds_kmh(positions["shuttle"], record.fps or 30.0, cfg.get("speed_smoothing", 3))
        for f, v in zip(record.frames, kmh, strict=True):
            f.shuttle_speed_kmh = None if np.isnan(v) else round(float(v), 1)
        for h in record.hits:
            speed = hit_speed(kmh, h.frame, cfg.get("hit_speed_frames", 5))
            h.speed_kmh = None if speed is None else round(speed, 1)
        dropped = int(np.isnan(kmh).sum() - np.isnan(positions["shuttle"]).any(axis=1).sum())
        if dropped > 0:
            log.info("%d frames without a plausible speed estimate", dropped)
    else:  # speeds need court meters
        for f in record.frames:
            f.shuttle_speed_kmh = None
        for h in record.hits:
            h.speed_kmh = None
    count_strokes(record)
    record.summary = build_summary(record)
    ctx.progress(1.0)
    return record
