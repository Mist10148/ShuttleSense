"""Request and response bodies for the REST API (docs/API.md)."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from shuttlesense.coach.personality.models import PersonalityConfig
from shuttlesense.schema import (
    Call,
    CourtType,
    DecisionReason,
    GameService,
    LineCall,
    Mode,
    PlayerId,
    PlayerSide,
    Rally,
    Score,
    ScorePair,
    StrokeModel,
)

JobStatus = Literal["queued", "running", "needs_selection", "done", "failed", "cancelled"]
StageStatus = Literal["pending", "running", "done", "skipped", "failed"]


def utcnow() -> datetime:
    return datetime.now(UTC)


class Health(BaseModel):
    status: Literal["ok"] = "ok"
    version: str
    schema_version: str
    device: str
    auth_required: bool
    stages: list[str]
    # Installed stroke models: "cnn", "lstm", "rf", and "ensemble" when all three are (D28, D37).
    stroke_models: list[str] = Field(default_factory=list)
    chat_available: bool = False  # a Claude API key is configured on this backend
    chat_max_messages: int = 0  # questions allowed per session
    watch_video: bool = True
    watch_match_type: bool = True
    watch_realtime: bool = True
    watch_background: bool = True
    practice_video: bool = False
    practice_watch: bool = False
    practice_court_watch: bool = False
    practice_general: bool = False


class MatchTypeRequest(BaseModel):
    corners: list[tuple[float, float]] = Field(min_length=4, max_length=4)


class ChatRequest(BaseModel):
    """POST /jobs/{id}/chat."""

    message: str = Field(min_length=1, max_length=1000)
    # How the coach should talk (D50); absent means the default coach.
    personality: PersonalityConfig | None = None

    @field_validator("message")
    @classmethod
    def _not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("message is empty")
        return value


class VideoInfoOut(BaseModel):
    id: str
    filename: str
    size_bytes: int
    fps: float
    width: int
    height: int
    num_frames: int
    duration_s: float
    created_at: datetime = Field(default_factory=utcnow)


def check_first_service(
    first_server: str | None,
    server_id: str | None,
    receiver_id: str | None,
    court: str = "doubles",
) -> None:
    """Raise ValueError unless the doubles first server and receiver make sense together."""
    if (server_id is None) != (receiver_id is None):
        raise ValueError("first_server_id and first_receiver_id go together")
    if server_id is None or receiver_id is None:
        return
    if court != "doubles":
        raise ValueError("first_server_id and first_receiver_id are for doubles only")
    if server_id[:3] == receiver_id[:3]:
        raise ValueError("the first server and receiver must be on opposite sides")
    if first_server is not None and not server_id.startswith(first_server):
        raise ValueError("first_server_id must be on the first_server side")


class JobCreate(BaseModel):
    video_id: str
    court_corners_px: list[tuple[float, float]] | None = Field(
        default=None, min_length=4, max_length=4
    )
    overlays: list[str] | None = None
    referee: bool = False
    start_score: ScorePair | None = None  # for clips that start mid-game
    best_of: Literal[1, 3] = 1  # games in the match
    start_games: ScorePair | None = None  # games each side already won (joined mid-match)
    # v1.7: the players change ends by the rules and the score goes with them. Send
    # false for players who stay put; a change by hand (POST .../score/ends) works
    # either way.
    auto_change_ends: bool = True
    first_server: PlayerSide | None = None  # who serves the first rally, if known
    court: CourtType = "singles"  # doubles: four players and the doubles lines (Phase 9)
    # Doubles: who serves and receives the first rally (both or neither, opposite sides).
    first_server_id: PlayerId | None = None
    first_receiver_id: PlayerId | None = None
    # Which stroke classifier labels the hits (D28). None: the server's default
    # (`stages.strokes.algorithm` in pipeline.yaml).
    stroke_model: StrokeModel | None = None

    @model_validator(mode="after")
    def _doubles_service(self) -> JobCreate:
        check_first_service(
            self.first_server, self.first_server_id, self.first_receiver_id, self.court
        )
        return self


class RenderRequest(BaseModel):
    overlays: list[str]


class ScoreCorrectionIn(BaseModel):
    rally_index: int
    winner: PlayerSide | None  # None: the rally is undecided again
    reason: DecisionReason | None = None  # e.g. "let" when clearing a rally to replay it


class GameServiceIn(BaseModel):
    """Doubles: who serves and receives first in a game after the first (both, or neither
    to forget the game's slots). The game winner's side serves."""

    game: int = Field(ge=2, le=3)
    server_id: PlayerId | None = None
    receiver_id: PlayerId | None = None

    @model_validator(mode="after")
    def _pair(self) -> GameServiceIn:
        check_first_service(None, self.server_id, self.receiver_id)
        return self


class ScoreAwardIn(BaseModel):
    """A point for a rally the referee layer missed."""

    winner: PlayerSide
    frame: int | None = None  # where it happened; None: after the last rally
    reason: DecisionReason | None = None  # e.g. "fault", "service_fault"

    @field_validator("frame")
    @classmethod
    def _not_negative(cls, value: int | None) -> int | None:
        if value is not None and value < 0:
            raise ValueError("frame must not be negative")
        return value


class ScoreEndsIn(BaseModel):
    """The players changed ends at `frame`: early, late, or against the automatic change."""

    frame: int | None = None  # None: after the last rally

    @field_validator("frame")
    @classmethod
    def _not_negative(cls, value: int | None) -> int | None:
        if value is not None and value < 0:
            raise ValueError("frame must not be negative")
        return value


class ScoreConcedeIn(BaseModel):
    """The other side retired or gave a walkover: `winner` wins the match at `frame`."""

    winner: PlayerSide
    frame: int | None = None  # None: after the last rally

    @field_validator("frame")
    @classmethod
    def _not_negative(cls, value: int | None) -> int | None:
        if value is not None and value < 0:
            raise ValueError("frame must not be negative")
        return value


class ScoreUpdate(BaseModel):
    """PATCH /jobs/{id}/score response: the new score and every rally's score_after.

    `line_calls` is set by an undo, which can take back a line-call override (D32)."""

    score: Score
    rallies: list[Rally]
    line_calls: list[LineCall] | None = None


class LineCallOverrideBody(BaseModel):
    """PATCH /jobs/{id}/line-calls/{n}: confirm (same call) or override (other call)."""

    call: Call


class LineCallUpdate(BaseModel):
    """PATCH /jobs/{id}/line-calls/{n} response: calls, rallies and score after re-scoring."""

    line_calls: list[LineCall]
    score: Score
    rallies: list[Rally]


class StageState(BaseModel):
    name: str
    status: StageStatus = "pending"
    progress: float = 0.0


class JobOutputs(BaseModel):
    record: bool = False
    video: bool = False
    summary: bool = False
    hits_csv: bool = False
    rallies_csv: bool = False
    practice: bool = False


class Job(BaseModel):
    id: str
    video_id: str
    status: JobStatus = "queued"
    queue_position: int | None = None
    current_stage: str | None = None
    progress: float = 0.0
    stages: list[StageState] = Field(default_factory=list)
    error: str | None = None
    created_at: datetime = Field(default_factory=utcnow)
    started_at: datetime | None = None
    finished_at: datetime | None = None
    outputs: JobOutputs = Field(default_factory=JobOutputs)
    # Request parameters, kept so a job can be re-run or re-rendered.
    court_corners_px: list[tuple[float, float]] | None = None
    overlays: list[str] = Field(default_factory=list)
    referee: bool = False
    start_score: ScorePair | None = None
    best_of: Literal[1, 3] = 1
    start_games: ScorePair | None = None
    # False for jobs stored before clip record 1.7, so a re-render scores them as before.
    auto_change_ends: bool = False
    first_server: PlayerSide | None = None
    court: CourtType = "singles"
    first_server_id: PlayerId | None = None
    first_receiver_id: PlayerId | None = None
    # Doubles: who serves and receives first in games 2 and 3, named after each game (D23).
    game_service: list[GameService] = Field(default_factory=list)
    stroke_model: StrokeModel = "cnn"
    mode: Mode = "upload"  # "live" for a saved live session (its video is the recording)
    watch_position_s: float | None = Field(default=None, exclude_if=lambda v: v is None)
    watch_analysis_s: float | None = Field(default=None, exclude_if=lambda v: v is None)
    watch_target_s: float | None = Field(default=None, exclude_if=lambda v: v is None)
    watch_focused_analysis: bool = False
    practice_setup: dict | None = None
    practice_selections: dict[int, tuple[float, float, float, float]] = Field(default_factory=dict)
    practice_gaps: list[tuple[int, int]] = Field(default_factory=list)
    practice_selection_frame: int | None = None
