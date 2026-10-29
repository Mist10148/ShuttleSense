"""Clip record schema v1.0 — the shared per-clip data format.

This module is the source of truth for docs/DATA_FORMAT.md. Every pipeline stage
reads and writes a ClipRecord; the API serves it as JSON to the app.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field

SCHEMA_VERSION = "1.0"

PlayerSide = Literal["near", "far"]
StrokeClass = Literal["smash", "clear", "drop", "net_shot", "lift", "serve"]
RallyState = Literal["in_play", "between_rallies"]

STROKE_CLASSES: tuple[StrokeClass, ...] = ("smash", "clear", "drop", "net_shot", "lift", "serve")
NUM_KEYPOINTS = 17  # COCO layout

# Singles court in meters: width (sideline to sideline) x length (baseline to baseline).
COURT_SIZE_M: tuple[float, float] = (5.18, 13.40)

Point = tuple[float, float]


class Shuttle(BaseModel):
    x: float | None = None
    y: float | None = None
    visible: Literal[0, 1] = 0


class Player(BaseModel):
    bbox: tuple[float, float, float, float]  # x, y, w, h in pixels
    keypoints: list[tuple[float, float, float]] = Field(default_factory=list)  # [x, y, score] x 17
    score: float = 0.0


class Players(BaseModel):
    near: Player | None = None
    far: Player | None = None


class CourtPositions(BaseModel):
    near: Point | None = None
    far: Point | None = None
    shuttle: Point | None = None


class Frame(BaseModel):
    frame: int
    shuttle: Shuttle | None = None
    players: Players = Field(default_factory=Players)
    court_positions: CourtPositions | None = None
    shuttle_speed_kmh: float | None = None
    rally_state: RallyState | None = None


class Court(BaseModel):
    corners_px: tuple[Point, Point, Point, Point]  # near-left, near-right, far-right, far-left
    homography: list[list[float]]  # 3x3, image px -> court meters
    court_size_m: Point = COURT_SIZE_M


class FeedbackItem(BaseModel):
    rule: str
    passed: bool
    tip: str | None = None


class Hit(BaseModel):
    id: int
    frame: int
    time_s: float
    player: PlayerSide
    stroke: StrokeClass | None = None
    confidence: float | None = None
    class_probs: dict[StrokeClass, float] | None = None
    speed_kmh: float | None = None
    feedback: list[FeedbackItem] = Field(default_factory=list)
    rally_index: int | None = None


class Landing(BaseModel):
    x_m: float
    y_m: float
    in_court: bool
    confidence: float


class ScorePair(BaseModel):
    near: int = 0
    far: int = 0


class Rally(BaseModel):
    index: int
    start_frame: int
    end_frame: int
    stroke_count: int = 0
    landing: Landing | None = None
    winner: PlayerSide | None = None
    score_after: ScorePair | None = None


class ScoreCorrection(BaseModel):
    rally_index: int
    winner_before: PlayerSide | None
    winner_after: PlayerSide
    at: datetime


class Score(ScorePair):
    corrections: list[ScoreCorrection] = Field(default_factory=list)


class PlayerSummary(BaseModel):
    hits: int = 0
    stroke_counts: dict[StrokeClass, int] = Field(default_factory=dict)
    peak_speed_kmh: float | None = None


class Summary(BaseModel):
    total_hits: int = 0
    stroke_counts: dict[StrokeClass, int] = Field(default_factory=dict)
    peak_speed_kmh: float | None = None
    per_player: dict[PlayerSide, PlayerSummary] = Field(default_factory=dict)


class ClipRecord(BaseModel):
    schema_version: str = SCHEMA_VERSION
    clip_id: str
    source_name: str | None = None
    fps: float
    width: int
    height: int
    num_frames: int
    court: Court | None = None
    frames: list[Frame] = Field(default_factory=list)
    hits: list[Hit] = Field(default_factory=list)
    rallies: list[Rally] = Field(default_factory=list)
    score: Score | None = None
    summary: Summary | None = None
