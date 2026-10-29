"""Stroke inference stage (F6, FR-6)."""

from __future__ import annotations

from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill hits[].stroke, confidence and class_probs.

    TODO(T3.10): build the same feature window as scripts/extract_features.py around each hit,
    load weights/strokes/stroke_cnn.pt, softmax over STROKE_CLASSES.
    """
    ctx.progress(1.0)
    return record
