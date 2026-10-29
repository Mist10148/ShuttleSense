"""Form feedback rules from pose angles (F8, FR-8).

Each stroke class gets at least 2 rules (contact height vs head, elbow angle at contact,
arm extension, follow-through). Rules are documented in docs/FEEDBACK_RULES.md (task T5.8).
"""

from __future__ import annotations

import numpy as np

from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext


def joint_angle(a: np.ndarray, b: np.ndarray, c: np.ndarray) -> float:
    """Angle ABC in degrees, e.g. shoulder-elbow-wrist for the elbow angle."""
    ba, bc = a - b, c - b
    cos = float(np.dot(ba, bc) / (np.linalg.norm(ba) * np.linalg.norm(bc) + 1e-9))
    return float(np.degrees(np.arccos(np.clip(cos, -1.0, 1.0))))


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill hits[].feedback.

    TODO(T5.8): evaluate per-class rules on the hitter's keypoints at the hit frame and
    write one FeedbackItem per rule with a short tip when it fails.
    """
    ctx.progress(1.0)
    return record
