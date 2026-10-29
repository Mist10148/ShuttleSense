"""Rally state and landing detection (F14/F15, FR-14/FR-15)."""

from __future__ import annotations

from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill frames[].rally_state, rallies[] and score.

    TODO(T6.1): rally starts at a serve hit, ends when the shuttle is lost or stationary
    on the floor for N frames (configs/pipeline.yaml).
    TODO(T6.2): landing point on the court plane and in/out with confidence.
    TODO(T6.3): award rallies and keep score with scoring.py.
    """
    ctx.progress(1.0)
    return record
