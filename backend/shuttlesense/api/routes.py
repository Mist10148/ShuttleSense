"""REST endpoints. Keep in sync with docs/API.md and app/lib/data/api_client.dart."""

from __future__ import annotations

import asyncio
import hmac
import json
import time
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Annotated

from fastapi import (
    APIRouter,
    Depends,
    File,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
)
from fastapi import (
    Path as PathParam,
)
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

from shuttlesense import __version__
from shuttlesense.analytics import build_summary, write_exports
from shuttlesense.api.jobs import JobBusy, JobManager, VideoGone
from shuttlesense.api.models import (
    ChatRequest,
    Health,
    Job,
    JobCreate,
    LineCallOverrideBody,
    LineCallUpdate,
    RenderRequest,
    ScoreCorrectionIn,
    ScoreUpdate,
    VideoInfoOut,
    utcnow,
)
from shuttlesense.api.settings import Settings, get_settings
from shuttlesense.api.storage import Storage, new_id
from shuttlesense.court import check_court_area, validate_corners
from shuttlesense.feedback import build_coaching
from shuttlesense.io import SUPPORTED_SUFFIXES, check_duration, probe, read_frame
from shuttlesense.referee import (
    LineCallOverrideIn,
    apply_corrections,
    apply_user_changes,
    build_events,
    game_winner,
    load_overrides,
    save_corrections,
    save_overrides,
)
from shuttlesense.render import OVERLAYS
from shuttlesense.schema import (
    SCHEMA_VERSION,
    Chat,
    ChatMessage,
    ScoreCorrection,
    load_record,
    migrate,
)


def get_storage(request: Request) -> Storage:
    return request.app.state.storage


def get_jobs(request: Request) -> JobManager:
    return request.app.state.jobs


def require_token(
    request: Request,
    settings: Annotated[Settings, Depends(get_settings)],
    token: Annotated[
        str | None, Query(description="Alternative to the header for <video> tags")
    ] = None,
) -> None:
    """Bearer token check when SHUTTLESENSE_TOKEN is set."""
    if not settings.token:
        return
    scheme, _, value = request.headers.get("authorization", "").partition(" ")
    supplied = value.strip() if scheme.lower() == "bearer" else token  # schemes ignore case
    if not supplied or not hmac.compare_digest(supplied.encode(), settings.token.encode()):
        raise HTTPException(status_code=401, detail="missing or invalid token")


StorageDep = Annotated[Storage, Depends(get_storage)]
JobsDep = Annotated[JobManager, Depends(get_jobs)]

public = APIRouter()
router = APIRouter(dependencies=[Depends(require_token)])

CHAT_ANSWER_TIMEOUT_S = 300.0  # longest a streamed coach answer may hold its job's chat


# Health -----------------------------------------------------------------------


@public.get("/health", response_model=Health)
def health(request: Request, settings: Annotated[Settings, Depends(get_settings)]) -> Health:
    return Health(
        version=__version__,
        schema_version=SCHEMA_VERSION,
        device=request.app.state.device,
        auth_required=bool(settings.token),
        stages=request.app.state.available_stages,
        chat_available=request.app.state.chat_client is not None,
        chat_max_messages=settings.chat_max_messages,
    )


# Videos -----------------------------------------------------------------------


def _video_or_404(storage: Storage, video_id: str) -> VideoInfoOut:
    info = storage.load_video_meta(video_id)
    if info is None:
        raise HTTPException(status_code=404, detail="video not found")
    return info


@router.post("/videos", response_model=VideoInfoOut, status_code=201)
def upload_video(
    request: Request,
    file: Annotated[UploadFile, File()],
    storage: StorageDep,
    settings: Annotated[Settings, Depends(get_settings)],
) -> VideoInfoOut:
    suffix = Path(file.filename or "").suffix.lower()
    if suffix not in SUPPORTED_SUFFIXES:
        raise HTTPException(status_code=415, detail="unsupported video type; use MP4, MOV or AVI")
    limit = settings.max_upload_mb * 1024 * 1024
    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > limit + 64 * 1024:  # allow for multipart framing
        raise HTTPException(status_code=413, detail="upload too large")
    video_id = new_id()
    target_dir = storage.video_dir(video_id)
    target_dir.mkdir(parents=True)
    target = target_dir / f"source{suffix}"
    saved = False
    try:
        size = 0
        with target.open("wb") as out:
            while chunk := file.file.read(1024 * 1024):
                size += len(chunk)
                if size > limit:
                    raise HTTPException(status_code=413, detail="upload too large")
                out.write(chunk)
        try:
            meta = probe(target)
        except ValueError as exc:
            raise HTTPException(status_code=415, detail=str(exc)) from exc
        try:
            io_cfg = request.app.state.jobs.config.get("stages", {}).get("io", {})
            check_duration(meta, io_cfg.get("max_duration_s", 300))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        saved = True
    finally:
        if not saved:  # rejected, or the client went away mid-upload
            storage.delete_video(video_id)
    info = VideoInfoOut(
        id=video_id,
        filename=file.filename or target.name,
        size_bytes=size,
        fps=meta.fps,
        width=meta.width,
        height=meta.height,
        num_frames=meta.num_frames,
        duration_s=meta.duration_s,
    )
    storage.save_video_meta(info)
    return info


@router.get("/videos/{video_id}", response_model=VideoInfoOut)
def get_video(video_id: str, storage: StorageDep) -> VideoInfoOut:
    return _video_or_404(storage, video_id)


@router.get("/videos/{video_id}/frames/{n}")
def get_frame(
    video_id: str,
    n: Annotated[int, PathParam(ge=0)],
    storage: StorageDep,
    max_width: Annotated[int, Query(ge=64, le=3840)] = 1280,
) -> Response:
    import cv2

    info = _video_or_404(storage, video_id)
    source = storage.video_source(video_id)
    in_range = info.num_frames <= 0 or n < info.num_frames  # 0 = unknown frame count
    frame = read_frame(source, n) if source and in_range else None
    if frame is None:
        raise HTTPException(status_code=404, detail="frame not found")
    if frame.shape[1] > max_width:
        scale = max_width / frame.shape[1]
        frame = cv2.resize(frame, (max_width, round(frame.shape[0] * scale)))
    ok, jpeg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
    if not ok:
        raise HTTPException(status_code=500, detail="could not encode frame")
    return Response(
        content=jpeg.tobytes(),
        media_type="image/jpeg",
        headers={"X-Frame-Width": str(info.width), "X-Frame-Height": str(info.height)},
    )


@router.delete("/videos/{video_id}", status_code=204)
def delete_video(video_id: str, storage: StorageDep, jobs: JobsDep) -> Response:
    _video_or_404(storage, video_id)
    # Hide the video first so a POST /jobs racing this delete gets a 404, not an orphan job.
    storage.hide_video(video_id)
    jobs.delete_for_video(video_id)
    storage.delete_video(video_id)
    return Response(status_code=204)


# Jobs -------------------------------------------------------------------------


def _job_or_404(jobs: JobManager, job_id: str) -> Job:
    job = jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    return job


def _check_overlays(names: list[str] | None) -> list[str]:
    if names is None:
        return list(OVERLAYS)
    unknown = sorted(set(names) - set(OVERLAYS))
    if unknown:
        raise HTTPException(status_code=400, detail=f"unknown overlays: {', '.join(unknown)}")
    return names


@router.post("/jobs", response_model=Job, status_code=202)
def create_job(body: JobCreate, storage: StorageDep, jobs: JobsDep) -> Job:
    video = _video_or_404(storage, body.video_id)
    if body.start_score is not None:
        if min(body.start_score.near, body.start_score.far) < 0:
            raise HTTPException(status_code=400, detail="start_score cannot be negative")
        if game_winner(body.start_score.near, body.start_score.far) is not None:
            raise HTTPException(status_code=400, detail="start_score is already a finished game")
    if body.court_corners_px is not None:
        try:
            validate_corners(body.court_corners_px)
            check_court_area(body.court_corners_px, (video.width, video.height))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    job = Job(
        id=new_id(),
        video_id=body.video_id,
        court_corners_px=body.court_corners_px,
        overlays=_check_overlays(body.overlays),
        referee=body.referee,
        start_score=body.start_score,
    )
    try:
        return jobs.submit(job)
    except VideoGone as exc:
        raise HTTPException(status_code=404, detail="video not found") from exc


@router.get("/jobs", response_model=list[Job])
def list_jobs(jobs: JobsDep, limit: Annotated[int, Query(ge=1, le=500)] = 50) -> list[Job]:
    return jobs.list(limit)


@router.get("/jobs/{job_id}", response_model=Job)
def get_job(job_id: str, jobs: JobsDep) -> Job:
    return _job_or_404(jobs, job_id)


def _feedback_config(jobs: JobManager) -> dict:
    return jobs.config.get("stages", {}).get("feedback", {})


def _output_or_404(storage: Storage, jobs: JobManager, job_id: str, key: str) -> Path:
    _job_or_404(jobs, job_id)
    path = storage.output_path(job_id, key)
    if not path.exists():
        raise HTTPException(status_code=404, detail=f"{path.name} not available yet")
    return path


@router.get("/jobs/{job_id}/record")
def get_record(job_id: str, storage: StorageDep, jobs: JobsDep) -> Response:
    path = _output_or_404(storage, jobs, job_id, "record")
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") == SCHEMA_VERSION:
        return FileResponse(path, media_type="application/json")
    return JSONResponse(migrate(data))  # a job from before the last schema bump


@router.get("/jobs/{job_id}/video")
def get_annotated_video(job_id: str, storage: StorageDep, jobs: JobsDep) -> FileResponse:
    # FileResponse handles HTTP range requests, so players can seek.
    return FileResponse(_output_or_404(storage, jobs, job_id, "video"), media_type="video/mp4")


@router.get("/jobs/{job_id}/summary.json")
def get_summary(job_id: str, storage: StorageDep, jobs: JobsDep) -> FileResponse:
    path = _output_or_404(storage, jobs, job_id, "summary")
    return FileResponse(path, media_type="application/json", filename=f"{job_id}_summary.json")


@router.get("/jobs/{job_id}/hits.csv")
def get_hits_csv(job_id: str, storage: StorageDep, jobs: JobsDep) -> FileResponse:
    path = _output_or_404(storage, jobs, job_id, "hits_csv")
    return FileResponse(path, media_type="text/csv", filename=f"{job_id}_hits.csv")


@router.get("/jobs/{job_id}/rallies.csv")
def get_rallies_csv(job_id: str, storage: StorageDep, jobs: JobsDep) -> FileResponse:
    path = _output_or_404(storage, jobs, job_id, "rallies_csv")
    return FileResponse(path, media_type="text/csv", filename=f"{job_id}_rallies.csv")


@router.post("/jobs/{job_id}/render", response_model=Job, status_code=202)
def rerender(job_id: str, body: RenderRequest, request: Request, jobs: JobsDep) -> Job:
    job = _job_or_404(jobs, job_id)
    overlays = _check_overlays(body.overlays)
    if job.status != "done" and not (job.status == "failed" and jobs.has_outputs(job_id)):
        raise HTTPException(status_code=409, detail="only finished jobs can be re-rendered")
    # The run would rewrite record.json under an answer that is about to be saved to it.
    if _chat_in_flight(request, job_id):
        raise HTTPException(status_code=409, detail="a coach answer is still being written")
    try:
        updated = jobs.rerender(job_id, overlays)
    except JobBusy as exc:
        raise HTTPException(status_code=409, detail="job is already queued or running") from exc
    if updated is None:
        raise HTTPException(status_code=404, detail="job not found")
    return updated


@router.patch("/jobs/{job_id}/score", response_model=ScoreUpdate)
def correct_score(
    job_id: str, body: ScoreCorrectionIn, storage: StorageDep, jobs: JobsDep
) -> ScoreUpdate:
    job = _job_or_404(jobs, job_id)
    if job.status != "done":  # a re-render is about to rewrite record.json
        raise HTTPException(status_code=409, detail="wait until the job has finished")
    path = _output_or_404(storage, jobs, job_id, "record")
    with jobs.job_lock(job_id):  # read-modify-write of record.json
        record = load_record(path.read_text(encoding="utf-8"))
        if record.score is None or not record.rallies:
            raise HTTPException(status_code=409, detail="referee stage did not run for this job")
        rally = next((r for r in record.rallies if r.index == body.rally_index), None)
        if rally is None:
            raise HTTPException(status_code=404, detail="rally not found")
        correction = ScoreCorrection(
            rally_index=rally.index,
            winner_before=rally.winner,
            winner_after=body.winner,
            at=utcnow(),
        )
        corrections = [*record.score.corrections, correction]
        apply_corrections(record, corrections, job.start_score)
        record.rally_events = build_events(record)  # rally_end winners and score events
        record.summary = build_summary(record)
        record.coaching = build_coaching(record, _feedback_config(jobs))
        save_corrections(storage.job_dir(job_id), corrections)
        write_exports(record, storage.job_dir(job_id))
    return ScoreUpdate(score=record.score, rallies=record.rallies)


@router.patch("/jobs/{job_id}/line-calls/{call_id}", response_model=LineCallUpdate)
def override_line_call(
    job_id: str, call_id: int, body: LineCallOverrideBody, storage: StorageDep, jobs: JobsDep
) -> LineCallUpdate:
    """Confirm or override an automated call; the rally winner and score follow."""
    job = _job_or_404(jobs, job_id)
    if job.status != "done":
        raise HTTPException(status_code=409, detail="wait until the job has finished")
    path = _output_or_404(storage, jobs, job_id, "record")
    job_dir = storage.job_dir(job_id)
    with jobs.job_lock(job_id):
        record = load_record(path.read_text(encoding="utf-8"))
        call = next((c for c in record.line_calls if c.id == call_id), None)
        if call is None or record.score is None:
            raise HTTPException(status_code=404, detail="line call not found")
        overrides = [o for o in load_overrides(job_dir) if o.rally_index != call.rally_index]
        overrides.append(
            LineCallOverrideIn(rally_index=call.rally_index, call=body.call, at=utcnow())
        )
        save_overrides(job_dir, overrides)
        apply_user_changes(record, job_dir, job.start_score)
        record.summary = build_summary(record)
        record.coaching = build_coaching(record, _feedback_config(jobs))
        write_exports(record, job_dir)
    return LineCallUpdate(line_calls=record.line_calls, score=record.score, rallies=record.rallies)


@router.post("/jobs/{job_id}/chat")
async def chat(
    job_id: str,
    body: ChatRequest,
    request: Request,
    storage: StorageDep,
    jobs: JobsDep,
    settings: Annotated[Settings, Depends(get_settings)],
) -> StreamingResponse:
    """Ask the coach about a finished job; the answer streams as Server-Sent Events."""
    from shuttlesense.coach.chat import ChatError, ChatSettings, stream_answer
    from shuttlesense.coach.digest import build_digest

    client = request.app.state.chat_client
    if client is None:
        raise HTTPException(status_code=503, detail="coach chat is off: no Claude API key set")
    job = _job_or_404(jobs, job_id)
    if job.status != "done":
        raise HTTPException(status_code=409, detail="wait until the job has finished")
    path = _output_or_404(storage, jobs, job_id, "record")
    record = await asyncio.to_thread(lambda: load_record(path.read_text(encoding="utf-8")))
    history = record.chat.messages if record.chat else []
    if sum(m.role == "user" for m in history) >= settings.chat_max_messages:
        raise HTTPException(status_code=429, detail="question limit for this session reached")
    # One question at a time per job, so parallel requests cannot get past the limit above
    # (the history only grows once an answer is saved).
    # The mark expires on its own in case the stream is never started.
    if _chat_in_flight(request, job_id):
        raise HTTPException(status_code=409, detail="a question is already being answered")
    answering: dict[str, float] = request.app.state.chat_answering
    answering[job_id] = time.monotonic()
    question = ChatMessage(role="user", text=body.message.strip(), at=utcnow())
    digest = build_digest(record, settings.chat_max_digest_chars)
    chat_settings = ChatSettings(model=settings.chat_model, effort=settings.chat_effort)

    async def events() -> AsyncIterator[str]:
        try:
            async for event in stream_answer(client, digest, history, question.text, chat_settings):
                if event["type"] == "done":
                    answer = ChatMessage.model_validate(event["message"])
                    await asyncio.to_thread(_save_chat, storage, jobs, job_id, [question, answer])
                yield f"data: {json.dumps(event)}\n\n"
        except ChatError as exc:
            error = {"type": "error", "status": exc.status, "detail": exc.detail}
            yield f"data: {json.dumps(error)}\n\n"
        finally:
            answering.pop(job_id, None)

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache"})  # fmt: skip


def _chat_in_flight(request: Request, job_id: str) -> bool:
    answering: dict[str, float] = request.app.state.chat_answering
    return time.monotonic() - answering.get(job_id, -CHAT_ANSWER_TIMEOUT_S) < CHAT_ANSWER_TIMEOUT_S


def _save_chat(
    storage: Storage, jobs: JobManager, job_id: str, messages: list[ChatMessage]
) -> None:
    path = storage.output_path(job_id, "record")
    with jobs.job_lock(job_id):  # read-modify-write of record.json
        record = load_record(path.read_text(encoding="utf-8"))
        record.chat = record.chat or Chat()
        record.chat.messages.extend(messages)
        write_exports(record, storage.job_dir(job_id))


@router.delete("/jobs/{job_id}", status_code=204)
def delete_job(job_id: str, jobs: JobsDep) -> Response:
    if not jobs.cancel_or_delete(job_id):
        raise HTTPException(status_code=404, detail="job not found")
    return Response(status_code=204)
