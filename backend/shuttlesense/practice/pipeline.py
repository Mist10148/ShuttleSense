"""Court-independent, pausable single-player practice analysis."""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Literal

from pydantic import BaseModel, Field, model_validator

from shuttlesense.practice.evidence import (
    Arm,
    AttemptEvidence,
    SelectedPlayerTracker,
    Stroke,
    assess_attempt,
)
from shuttlesense.schema import Player


class PracticeSetup(BaseModel):
    video_id: str
    stroke: Stroke
    arm: Arm
    attempt_seconds: list[float] = Field(default_factory=list, max_length=100)
    selection_frame: int = Field(default=0, ge=0)
    selected_bbox: tuple[float, float, float, float]

    @model_validator(mode="after")
    def valid(self) -> PracticeSetup:
        if any(not math.isfinite(t) or t < 0 for t in self.attempt_seconds):
            raise ValueError("attempt times must be finite and non-negative")
        if len(set(self.attempt_seconds)) != len(self.attempt_seconds):
            raise ValueError("attempt times must be distinct")
        validate_bbox(self.selected_bbox)
        self.attempt_seconds.sort()
        return self


def validate_bbox(box: tuple[float, float, float, float]) -> None:
    if not all(math.isfinite(x) for x in box) or box[2] <= 0 or box[3] <= 0:
        raise ValueError("selection box must have finite values and positive dimensions")


@dataclass
class PracticeAnalyzer:
    setup: PracticeSetup
    fps: float
    frame_count: int
    tracker: SelectedPlayerTracker = field(init=False)
    status: Literal["ready", "running", "needs_selection", "done"] = "ready"
    next_frame: int = field(init=False)
    observations: list[AttemptEvidence] = field(default_factory=list)
    _attempts: dict[int, list[float]] = field(init=False, repr=False)

    def __post_init__(self) -> None:
        if not math.isfinite(self.fps) or self.fps <= 0 or self.frame_count <= 0:
            raise ValueError("video must have valid frame rate and frame count")
        if self.setup.selection_frame >= self.frame_count:
            raise ValueError("selection frame is outside the video")
        self.next_frame = self.setup.selection_frame
        self.tracker = SelectedPlayerTracker(self.setup.selected_bbox)
        self._attempts = {}
        for seconds in self.setup.attempt_seconds:
            index = round(seconds * self.fps)
            if index < self.setup.selection_frame or index >= self.frame_count:
                raise ValueError("attempt time is outside the selected video segment")
            self._attempts.setdefault(index, []).append(seconds)

    def reselect(self, frame: int, bbox: tuple[float, float, float, float]) -> None:
        if self.status != "needs_selection" or frame != self.next_frame:
            raise ValueError("selection must be made on the frame where tracking stopped")
        validate_bbox(bbox)
        self.tracker = SelectedPlayerTracker(bbox)
        self.status = "ready"

    def process(self, frame: int, detections: list[Player]) -> Player | None:
        if self.status in ("done", "needs_selection") or frame != self.next_frame:
            raise ValueError("frame is not the next available frame")
        self.status = "running"
        player = self.tracker.update(detections)
        if player is None:
            self.status = "needs_selection"
            return None
        for seconds in self._attempts.get(frame, []):
            self.observations.append(
                assess_attempt(player, self.setup.stroke, self.setup.arm, seconds)
            )
        self.next_frame += 1
        if self.next_frame == self.frame_count:
            self.status = "done"
        return player

    def skip_untracked(self, frame: int) -> None:
        """Preserve marked attempts as unavailable while awaiting a later selection."""
        if self.status != "needs_selection" or frame != self.next_frame:
            raise ValueError("only the next untracked frame may be skipped")
        for seconds in self._attempts.get(frame, []):
            self.observations.append(
                assess_attempt(None, self.setup.stroke, self.setup.arm, seconds)
            )
        self.next_frame += 1
