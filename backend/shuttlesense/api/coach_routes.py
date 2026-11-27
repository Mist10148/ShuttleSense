"""RAG coach endpoints (D42): general chat and the AI coaching report. See docs/API.md."""

from __future__ import annotations

import asyncio
import json
import threading
import time
from collections import deque
from collections.abc import AsyncIterator
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field, field_validator

from shuttlesense.api.jobs import JobManager
from shuttlesense.api.routes import (
    _output_or_404,
    _require_done,
    get_jobs,
    get_storage,
    require_token,
)
from shuttlesense.api.settings import Settings, get_settings
from shuttlesense.api.storage import Storage
from shuttlesense.coach.personality.models import PersonalityConfig
from shuttlesense.coach.report import CoachReport
from shuttlesense.schema import ChatMessage, load_record

router = APIRouter(dependencies=[Depends(require_token)])

StorageDep = Annotated[Storage, Depends(get_storage)]
JobsDep = Annotated[JobManager, Depends(get_jobs)]
SettingsDep = Annotated[Settings, Depends(get_settings)]

RATE_PER_MINUTE = 10  # general coach questions per minute, per server process
ANSWER_TIMEOUT_S = 300.0


class CoachLimits:
    """One general question at a time and a per-minute cap; one report per job at a time."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.answering_since: float | None = None
        self.recent: deque[float] = deque()
        self.reports: set[str] = set()

    def start_answer(self) -> None:
        now = time.monotonic()
        with self.lock:
            if self.answering_since is not None and now - self.answering_since < ANSWER_TIMEOUT_S:
                raise HTTPException(status_code=409, detail="a question is already being answered")
            while self.recent and now - self.recent[0] > 60:
                self.recent.popleft()
            if len(self.recent) >= RATE_PER_MINUTE:
                raise HTTPException(status_code=429, detail="too many questions; wait a minute")
            self.recent.append(now)
            self.answering_since = now

    def end_answer(self) -> None:
        with self.lock:
            self.answering_since = None


class Turn(BaseModel):
    role: Literal["user", "assistant"]
    text: str = Field(max_length=8000)


class CoachChatRequest(BaseModel):
    """POST /coach/chat: a question plus the earlier turns the app keeps (not stored here)."""

    message: str = Field(min_length=1, max_length=1000)
    history: list[Turn] = Field(default_factory=list, max_length=40)
    # How the coach should talk (D50); absent means the default coach. The practice
    # follow-up inherits this field but does not use it yet.
    personality: PersonalityConfig | None = None

    @field_validator("message")
    @classmethod
    def _not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("message is blank")
        return value


def _coach(request: Request):
    coach = request.app.state.coach
    if coach.provider is None:
        raise HTTPException(
            status_code=503, detail="coach chat is off: no Gemini or Claude API key set"
        )
    return coach


@router.post("/coach/chat")
async def coach_chat(
    body: CoachChatRequest,
    request: Request,
    storage: StorageDep,
    jobs: JobsDep,
    settings: SettingsDep,
) -> StreamingResponse:
    """General and progress questions, not tied to one job; Server-Sent Events like
    POST /jobs/{id}/chat. Answers are not saved: the app keeps the conversation."""
    from shuttlesense.coach.chat import ChatError, ChatSettings, answer
    from shuttlesense.coach.personality import label_for

    coach = _coach(request)
    limits: CoachLimits = request.app.state.coach_limits
    limits.start_answer()
    now = time.time()
    history = [
        ChatMessage(role=t.role, text=t.text, at=now)  # type: ignore[arg-type]
        for t in body.history
    ]
    chat_settings = ChatSettings(top_k=settings.coach_top_k)

    def load_history():
        return coach.history.summaries(storage, jobs)

    async def events() -> AsyncIterator[str]:
        try:
            async for event in answer(
                coach,
                body.message.strip(),
                history,
                chat_settings,
                load_history=load_history,
                personality=body.personality,
            ):
                if event["type"] == "done" and (label := label_for(body.personality)):
                    event["message"]["personality_label"] = label
                yield f"data: {json.dumps(event)}\n\n"
        except ChatError as exc:
            error = {"type": "error", "status": exc.status, "detail": exc.detail}
            yield f"data: {json.dumps(error)}\n\n"
        finally:
            limits.end_answer()

    return StreamingResponse(
        events(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"}
    )


async def _report(
    job_id: str, request: Request, storage: StorageDep, jobs: JobsDep, settings: Settings,
    *, refresh: bool,
) -> CoachReport:  # fmt: skip
    from shuttlesense.coach.digest import build_digest
    from shuttlesense.coach.report import generate_report, load_cached, save_cached

    _require_done(jobs, job_id)
    path = _output_or_404(storage, jobs, job_id, "record")
    job_dir = storage.job_dir(job_id)
    if not refresh:
        cached = await asyncio.to_thread(load_cached, job_dir, path)
        if cached is not None:
            return cached
    limits: CoachLimits = request.app.state.coach_limits
    with limits.lock:
        if job_id in limits.reports:
            raise HTTPException(status_code=409, detail="the report is already being written")
        limits.reports.add(job_id)
    try:

        def read():
            with jobs.job_lock(job_id):
                _require_done(jobs, job_id)
                return load_record(path.read_text(encoding="utf-8")), path.stat().st_mtime

        record, mtime = await asyncio.to_thread(read)
        digest = build_digest(record, settings.chat_max_digest_chars)
        coach = request.app.state.coach
        report = await generate_report(coach, record, digest, settings.coach_top_k)
        # A rules report written because the model failed is not cached: the next request
        # tries the model again. The record must not have changed while the model wrote.
        fallback = coach.provider is not None and report.generated_by == "rules"
        if not fallback and path.exists() and path.stat().st_mtime == mtime:
            await asyncio.to_thread(save_cached, job_dir, path, report)
        return report
    finally:
        with limits.lock:
            limits.reports.discard(job_id)


@router.get("/jobs/{job_id}/coach/report", response_model=CoachReport)
async def get_coach_report(
    job_id: str, request: Request, storage: StorageDep, jobs: JobsDep, settings: SettingsDep
) -> CoachReport:
    """The cached report, or a new one (the rules report when no AI provider is set)."""
    return await _report(job_id, request, storage, jobs, settings, refresh=False)


@router.post("/jobs/{job_id}/coach/report", response_model=CoachReport)
async def refresh_coach_report(
    job_id: str, request: Request, storage: StorageDep, jobs: JobsDep, settings: SettingsDep
) -> CoachReport:
    """Write the report again, ignoring the cache."""
    return await _report(job_id, request, storage, jobs, settings, refresh=True)
