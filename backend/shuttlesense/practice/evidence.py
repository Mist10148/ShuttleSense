"""Conservative single-player selection and marked-attempt evidence.

This module deliberately makes no claim that a user-marked moment is shuttle contact.
It does not use court-relative identities or the match stroke classifier.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

import numpy as np
from pydantic import BaseModel, Field

from shuttlesense.schema import Player

Stroke = Literal["clear", "smash", "drop"]
Arm = Literal["left", "right"]


class Observation(BaseModel):
    rule: str
    moment_s: float = Field(ge=0, allow_inf_nan=False)
    status: Literal["observed", "unavailable"]
    value: float | None = None
    unit: str | None = None
    description: str
    provenance: Literal["user_marked", "automatic"] = "user_marked"


class AttemptEvidence(BaseModel):
    stroke: Stroke
    arm: Arm
    moment_s: float = Field(ge=0, allow_inf_nan=False)
    observations: list[Observation]
    limitation: str = (
        "The time and stroke were supplied by the user; shuttle contact was not verified. "
        "Measurements describe 2D image positions, not a diagnosis of technique."
    )


def _iou(a: tuple[float, float, float, float], b: tuple[float, float, float, float]) -> float:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    if min(aw, ah, bw, bh) <= 0:
        return 0.0
    intersection = max(0.0, min(ax + aw, bx + bw) - max(ax, bx)) * max(
        0.0, min(ay + ah, by + bh) - max(ay, by)
    )
    return intersection / max(aw * ah + bw * bh - intersection, 1e-9)


@dataclass
class SelectedPlayerTracker:
    """Track a user-selected box conservatively; loss requires explicit reselection.

    An IoU tracker cannot establish identity through long occlusions; once the detection
    is ambiguous or lost it refuses to reacquire automatically.
    """

    bbox: tuple[float, float, float, float]
    min_iou: float = 0.35
    lost: bool = False
    fresh_selection: bool = True

    def update(self, detections: list[Player]) -> Player | None:
        if self.lost:
            return None
        ranked = sorted(
            ((_iou(self.bbox, p.bbox), i) for i, p in enumerate(detections)), reverse=True
        )
        if not ranked or ranked[0][0] < self.min_iou:
            self.lost = True
            return None
        # Any other detection overlapping the target's last box makes attribution
        # uncertain, even if its IoU is lower than the normal candidate threshold.
        if (
            len(ranked) > 1
            and ranked[1][0] > 0
            and (not self.fresh_selection or ranked[0][0] - ranked[1][0] < 0.15)
        ):
            self.lost = True
            return None
        player = detections[ranked[0][1]]
        self.bbox = player.bbox
        self.fresh_selection = False
        return player


def assess_attempt(
    player: Player | None,
    stroke: Stroke,
    arm: Arm,
    moment_s: float,
    min_score: float = 0.5,
    provenance: Literal["user_marked", "automatic"] = "user_marked",
) -> AttemptEvidence:
    """Measure image-space positions at a user-marked instant without assigning fault.

    Existing match rules assume confirmed contact, so this function does not reuse their
    pass/fail labels or their thresholds for a shadow swing.
    """
    if not np.isfinite(moment_s) or moment_s < 0:
        raise ValueError("attempt time must be finite and non-negative")
    if stroke not in ("clear", "smash", "drop") or arm not in ("left", "right"):
        raise ValueError("unsupported stroke or racket arm")
    side = {"left": (5, 7, 9), "right": (6, 8, 10)}[arm]
    kps = player.keypoints if player is not None else []

    def point(index: int) -> np.ndarray | None:
        if index >= len(kps):
            return None
        p = np.asarray(kps[index], dtype=float)
        if p.shape != (3,) or not np.isfinite(p).all() or p[2] < min_score:
            return None
        return p[:2]

    shoulder, elbow, wrist = (point(i) for i in side)
    head = point(0)
    observations = []
    if wrist is not None and head is not None and player is not None and player.bbox[3] > 0:
        margin = float((head[1] - wrist[1]) / player.bbox[3])
        observations.append(
            Observation(
                rule="wrist_head_image_margin",
                moment_s=moment_s,
                status="observed",
                value=round(margin, 3),
                unit="bounding-box heights",
                description="Image-space wrist-to-nose distance; positive means wrist is higher.",
            )
        )
    else:
        observations.append(
            Observation(
                rule="wrist_head_image_margin",
                moment_s=moment_s,
                status="unavailable",
                description="Wrist or nose is not visible with sufficient confidence.",
            )
        )
    if shoulder is not None and elbow is not None and wrist is not None:
        a, b = shoulder - elbow, wrist - elbow
        denom = float(np.linalg.norm(a) * np.linalg.norm(b))
    else:
        denom = 0.0
    if denom > 1e-9:
        angle = float(np.degrees(np.arccos(np.clip(float(np.dot(a, b)) / denom, -1, 1))))
        observations.append(
            Observation(
                rule="elbow_image_angle",
                moment_s=moment_s,
                status="observed",
                value=round(angle, 1),
                unit="degrees",
                description="2D shoulder-elbow-wrist angle at the marked moment.",
            )
        )
    else:
        observations.append(
            Observation(
                rule="elbow_image_angle",
                moment_s=moment_s,
                status="unavailable",
                description="A required joint is missing or the image geometry is degenerate.",
            )
        )
    for observation in observations:
        observation.provenance = provenance
    limitation = (
        "This automatic stroke candidate is an estimate; shuttle contact was not verified. "
        "Measurements describe 2D image positions, not a diagnosis of technique."
        if provenance == "automatic"
        else AttemptEvidence.model_fields["limitation"].default
    )
    return AttemptEvidence(
        stroke=stroke, arm=arm, moment_s=moment_s, observations=observations, limitation=limitation
    )
