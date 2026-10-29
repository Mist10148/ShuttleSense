"""Request and response bodies for the REST API (docs/API.md)."""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Literal

from pydantic import BaseModel, Field

from shuttlesense.schema import PlayerSide

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


class RenderRequest(BaseModel):
    overlays: list[str]


class ScoreCorrectionIn(BaseModel):
    rally_index: int
    winner: PlayerSide


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
