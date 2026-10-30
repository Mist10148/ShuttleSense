"""Request and response bodies for the REST API (docs/API.md)."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field

from shuttlesense.schema import Call, LineCall, Mode, PlayerSide, Rally, Score, ScorePair

JobStatus = Literal["queued", "running", "done", "failed", "cancelled"]
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
    chat_available: bool = False  # a Claude API key is configured on this backend
    chat_max_messages: int = 0  # questions allowed per session


class ChatRequest(BaseModel):
    """POST /jobs/{id}/chat."""

    message: str = Field(min_length=1, max_length=1000)


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


class JobCreate(BaseModel):
    video_id: str
    court_corners_px: list[tuple[float, float]] | None = Field(
        default=None, min_length=4, max_length=4
    )
    overlays: list[str] | None = None
    referee: bool = False
    start_score: ScorePair | None = None  # for clips that start mid-game


class RenderRequest(BaseModel):
    overlays: list[str]


class ScoreCorrectionIn(BaseModel):
    rally_index: int
    winner: PlayerSide


class ScoreUpdate(BaseModel):
    """PATCH /jobs/{id}/score response: the new score and every rally's score_after."""

    score: Score
    rallies: list[Rally]


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
    mode: Mode = "upload"  # "live" for a saved live session (its video is the recording)
