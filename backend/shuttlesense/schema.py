"""Clip record schema v1.1 — the shared per-clip data format.

This module is the source of truth for docs/DATA_FORMAT.md. Every pipeline stage
reads and writes a ClipRecord; the API serves it as JSON to the app.
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field

SCHEMA_VERSION = "1.1"

PlayerSide = Literal["near", "far"]
StrokeClass = Literal["smash", "clear", "drop", "net_shot", "lift", "serve"]
RallyState = Literal["in_play", "between_rallies"]
Mode = Literal["upload", "live"]
Call = Literal["in", "out"]
CourtType = Literal["singles", "doubles"]
RallyEventType = Literal["rally_start", "rally_end", "hit", "landing", "score"]

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
    value: float | None = None  # measured quantity (degrees, ratio, ...), v1.1


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


class Moment(BaseModel):
    """A point on the timeline the app can seek to."""

    frame: int
    time_s: float
    hit_id: int | None = None


class LineCallOverride(BaseModel):
    call: Call
    at: datetime


class LineCall(BaseModel):
    """Automated in/out call for one landing; never an official call."""

    id: int
    rally_index: int
    frame: int
    time_s: float
    call: Call
    landing_xy: Point  # court meters
    margin_cm: float  # signed distance to the nearest relevant line, positive inside
    confidence: float
    uncertain: bool
    court: CourtType = "singles"
    override: LineCallOverride | None = None

    @property
    def effective_call(self) -> Call:
        return self.override.call if self.override else self.call


class RallyEvent(BaseModel):
    frame: int
    time_s: float
    type: RallyEventType
    rally_index: int | None = None
    data: dict[str, Any] = Field(default_factory=dict)


class SessionNote(BaseModel):
    id: str
    rule: str
    player: PlayerSide | None = None
    stroke: StrokeClass | None = None  # set when the rule was checked on one stroke class
    text: str
    count: int  # strokes that showed the pattern
    total: int  # strokes the rule was checked on
    severity: float
    moments: list[Moment] = Field(default_factory=list)


class Coaching(BaseModel):
    session_notes: list[SessionNote] = Field(default_factory=list)
    top_fixes: list[str] = Field(default_factory=list)  # SessionNote ids, most important first


class ChatMessage(BaseModel):
    role: Literal["user", "assistant"]
    text: str
    at: datetime
    citations: list[Moment] = Field(default_factory=list)


class Chat(BaseModel):
    messages: list[ChatMessage] = Field(default_factory=list)


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
    mode: Mode = "upload"
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
    line_calls: list[LineCall] = Field(default_factory=list)
    rally_events: list[RallyEvent] = Field(default_factory=list)
    coaching: Coaching | None = None
    chat: Chat | None = None


def migrate(data: dict[str, Any]) -> dict[str, Any]:
    """Upgrade an older record dict to SCHEMA_VERSION in place and return it.

    1.0 -> 1.1 only adds optional fields; the defaults fill them, and line calls and rally
    events are derived from the rallies so old jobs show calls in the app.
    """
    version = str(data.get("schema_version", "1.0"))
    if version == SCHEMA_VERSION:
        return data
    if version.split(".")[0] != SCHEMA_VERSION.split(".")[0]:
        raise ValueError(f"cannot migrate clip record {version} to {SCHEMA_VERSION}")
    data["schema_version"] = SCHEMA_VERSION
    data.setdefault("mode", "upload")
    if not data.get("line_calls") and data.get("rallies"):
        from shuttlesense.referee import build_events, derive_from_rallies

        record = ClipRecord.model_validate(data)
        record.line_calls = derive_from_rallies(record)
        record.rally_events = build_events(record)
        data["line_calls"] = [c.model_dump(mode="json") for c in record.line_calls]
        data["rally_events"] = [e.model_dump(mode="json") for e in record.rally_events]
    return data


def load_record(text: str | bytes) -> ClipRecord:
    """Parse a record.json of any supported version."""
    import json

    return ClipRecord.model_validate(migrate(json.loads(text)))
