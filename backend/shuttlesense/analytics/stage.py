"""Analytics stage: court positions, speeds, counts and summary (F10–F13)."""

from __future__ import annotations

from shuttlesense.analytics.export import build_summary
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill court_positions, speeds and summary.

    TODO(T5.4): project ankle midpoints and the shuttle onto the court with record.court.
    TODO(T5.6): fill frames[].shuttle_speed_kmh and hits[].speed_kmh via speeds_kmh().
    TODO(T5.7): stroke count per rally.
    """
    record.summary = build_summary(record)
    ctx.progress(1.0)
    return record
