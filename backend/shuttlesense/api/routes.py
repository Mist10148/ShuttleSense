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
    GameServiceIn,
    Health,
    Job,
    JobCreate,
    LineCallOverrideBody,
    LineCallUpdate,
    MatchTypeRequest,
    RenderRequest,
    ScoreAwardIn,
    ScoreConcedeIn,
    ScoreCorrectionIn,
    ScoreEndsIn,
    ScoreUpdate,
    VideoInfoOut,
    utcnow,
)
from shuttlesense.api.settings import Settings, get_settings
from shuttlesense.api.storage import Storage, new_id
from shuttlesense.court import check_court_area, validate_corners
from shuttlesense.courtside import log_decision, set_goal
from shuttlesense.feedback import build_coaching
from shuttlesense.io import SUPPORTED_SUFFIXES, check_duration, probe, read_frame
from shuttlesense.referee import (
    LineCallOverrideIn,
    after_the_match,
    apply_corrections,
    apply_user_changes,
    build_events,
    changes_finished_match,
    load_overrides,
    save_corrections,
    save_overrides,
    undo_last_decision,
    validate_start_games,
    validate_start_score,
)
from shuttlesense.render import OVERLAYS
from shuttlesense.schema import (
    SCHEMA_VERSION,
    Chat,
    ChatMessage,
    ClipRecord,
    GameService,
    PracticeGoal,
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


def _stroke_models(request: Request, settings: Settings) -> list[str]:
    """Checked on each call, so weights dropped in while the server runs show up."""
    from shuttlesense.strokes import registry

    if settings.fake_pipeline:
        return list(registry.ALGORITHMS)
    return registry.installed_models(request.app.state.jobs.config)


@public.get("/health", response_model=Health)
def health(request: Request, settings: Annotated[Settings, Depends(get_settings)]) -> Health:
    return Health(
        version=__version__,
        schema_version=SCHEMA_VERSION,
        device=request.app.state.device,
        auth_required=bool(settings.token),
        stages=request.app.state.available_stages,
        stroke_models=_stroke_models(request, settings),
        chat_available=request.app.state.chat_client is not None,
        chat_max_messages=settings.chat_max_messages,
        watch_match_type=not settings.fake_pipeline,
    )


# Videos -----------------------------------------------------------------------


@router.post("/videos/{video_id}/court-corners")
def suggest_court_corners(
    video_id: str, storage: StorageDep,
    frame: Annotated[int, Query(ge=0)] = 0,
) -> dict:
    """Suggest singles-reference corners on a source frame for user review."""
    from shuttlesense.court.detect import detect_corners

    info = _video_or_404(storage, video_id)
    source = storage.video_source(video_id)
    if source is None or (info.num_frames > 0 and frame >= info.num_frames):
        raise HTTPException(status_code=404, detail="frame not found")
    image = read_frame(source, frame)
    if image is None:
        raise HTTPException(status_code=404, detail="frame not found")
    corners = detect_corners(image)
    return {"corners": corners, "frame": frame}


@router.post("/videos/{video_id}/match-type")
def suggest_match_type(
    video_id: str,
    body: MatchTypeRequest,
    request: Request,
    storage: StorageDep,
    jobs: JobsDep,
    settings: Annotated[Settings, Depends(get_settings)],
) -> dict:
    from shuttlesense.api.match_type import detect_match_type
    from shuttlesense.stage import StageSkipped

    if settings.fake_pipeline:
        raise HTTPException(
            status_code=503, detail="Automatic detection is unavailable in demo mode"
        )
    info = _video_or_404(storage, video_id)
    source = storage.video_source(video_id)
    if source is None:
        raise HTTPException(status_code=404, detail="video not found")
    try:
        if any(not (0 <= x <= info.width and 0 <= y <= info.height) for x, y in body.corners):
            raise ValueError("Court corners must be inside the video frame")
        validate_corners(body.corners)
        check_court_area(body.corners, (info.width, info.height))
    except (ValueError, TypeError) as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not jobs.gpu.acquire(blocking=False):
        raise HTTPException(status_code=409, detail="Server is busy; try again or choose manually")
    try:
        return detect_match_type(source, body.corners, jobs.config, jobs.device)
    except (StageSkipped, ImportError, RuntimeError, OSError) as exc:
        raise HTTPException(status_code=503, detail=f"Player detection unavailable: {exc}") from exc
    finally:
        jobs.gpu.release()


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
            check_duration(meta, io_cfg.get("max_duration_s", 600))
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


@router.get("/videos/{video_id}/source")
def get_source_video(video_id: str, storage: StorageDep) -> FileResponse:
    _video_or_404(storage, video_id)
    source = storage.video_source(video_id)
    if source is None:
        raise HTTPException(status_code=404, detail="video not found")
    return FileResponse(source)


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
def delete_video(video_id: str, storage: StorageDep, jobs: JobsDep, request: Request) -> Response:
    with request.app.state.watch_background_lock:
        _video_or_404(storage, video_id)
        if any(
            worker.source_id == video_id and worker.thread.is_alive()
            for worker in request.app.state.watch_background.values()
        ):
            raise HTTPException(status_code=409, detail="Video is in use by background analysis")
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
    try:
        if body.start_score is not None:
            validate_start_score(body.start_score)
        validate_start_games(body.start_games, body.best_of)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
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
        best_of=body.best_of,
        start_games=body.start_games,
        auto_change_ends=body.auto_change_ends,
        first_server=body.first_server or (body.first_server_id or "")[:-2] or None,
        court=body.court,
        first_server_id=body.first_server_id,
        first_receiver_id=body.first_receiver_id,
        stroke_model=body.stroke_model or jobs.default_stroke_model(),
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
    # Checked again under the job lock, which the chat also takes to start an answer.
    def no_answer_in_flight() -> None:
        if _chat_in_flight(request, job_id):
            raise HTTPException(status_code=409, detail="a coach answer is still being written")

    no_answer_in_flight()
    try:
        updated = jobs.rerender(job_id, overlays, check=no_answer_in_flight)
    except JobBusy as exc:
        raise HTTPException(status_code=409, detail="job is already queued or running") from exc
    if updated is None:
        raise HTTPException(status_code=404, detail="job not found")
    return updated


@router.patch("/jobs/{job_id}/score", response_model=ScoreUpdate)
def correct_score(
    job_id: str, body: ScoreCorrectionIn, storage: StorageDep, jobs: JobsDep
) -> ScoreUpdate:
    _require_done(jobs, job_id)
    path = _output_or_404(storage, jobs, job_id, "record")
    with jobs.job_lock(job_id):  # read-modify-write of record.json
        job = _require_done(jobs, job_id)
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
            reason=body.reason,
        )
        corrections = [*record.score.corrections, correction]
        before = record.score.model_copy(deep=True)
        apply_corrections(record, corrections, job.start_score)
        if changes_finished_match(before, record.score):
            raise HTTPException(status_code=409, detail="the match is already won")
        log_decision(record, {"type": "correct", **body.model_dump()})
        _save_score(record, storage, jobs, job_id)
    return ScoreUpdate(score=record.score, rallies=record.rallies)


def _score_record(storage: Storage, jobs: JobManager, job_id: str) -> tuple[Job, Path]:
    job = _require_done(jobs, job_id)
    return job, _output_or_404(storage, jobs, job_id, "record")


def _require_done(jobs: JobManager, job_id: str) -> Job:
    """409 unless the job has finished. Call it again under `jobs.job_lock(job_id)`: a
    re-render queued between the first check and the lock would rewrite record.json."""
    job = _job_or_404(jobs, job_id)
    if job.status != "done":
        raise HTTPException(status_code=409, detail="wait until the job has finished")
    return job


def _save_score(record: ClipRecord, storage: Storage, jobs: JobManager, job_id: str) -> None:
    """After a score change: events, summary and notes follow; corrections are kept."""
    record.rally_events = build_events(record)  # rally_end winners and score events
    record.summary = build_summary(record)
    record.coaching = build_coaching(record, _feedback_config(jobs))
    save_corrections(storage.job_dir(job_id), record.score.corrections)
    write_exports(record, storage.job_dir(job_id))


@router.post("/jobs/{job_id}/score/award", response_model=ScoreUpdate)
def award_point(job_id: str, body: ScoreAwardIn, storage: StorageDep, jobs: JobsDep) -> ScoreUpdate:
    """Add a point for a rally the referee layer missed; it counts from `frame` on."""
    job, path = _score_record(storage, jobs, job_id)
    with jobs.job_lock(job_id):
        job = _require_done(jobs, job_id)
        record = load_record(path.read_text(encoding="utf-8"))
        if record.score is None:
            raise HTTPException(status_code=409, detail="referee stage did not run for this job")
        frame = body.frame if body.frame is not None else max(0, record.num_frames - 1)
        if frame >= max(record.num_frames, 1):
            raise HTTPException(status_code=400, detail="frame is past the end of the video")
        before = sum(1 for r in record.rallies if r.end_frame <= frame)
        award = ScoreCorrection(rally_index=before, winner_before=None, winner_after=body.winner,
                                at=utcnow(), kind="award", frame=frame,
                                reason=body.reason)  # fmt: skip
        before = record.score.model_copy(deep=True)
        apply_corrections(record, [*record.score.corrections, award], job.start_score)
        if changes_finished_match(before, record.score):
            raise HTTPException(status_code=409, detail="the match is already won")
        log_decision(
            record,
            {
                "type": "award",
                "frame": frame,
                "_game": before.game,
                **body.model_dump(exclude_none=True),
            },
        )
        _save_score(record, storage, jobs, job_id)
    return ScoreUpdate(score=record.score, rallies=record.rallies)


@router.post("/jobs/{job_id}/score/ends", response_model=ScoreUpdate)
def change_ends(job_id: str, body: ScoreEndsIn, storage: StorageDep, jobs: JobsDep) -> ScoreUpdate:
    """The players changed ends at `frame` (default: the end): the points, games and server
    go with them from there on. Given a second time at the same place it cancels the first,
    so it also takes back an automatic change the players did not make."""
    job, path = _score_record(storage, jobs, job_id)
    with jobs.job_lock(job_id):
        job = _require_done(jobs, job_id)
        record = load_record(path.read_text(encoding="utf-8"))
        if record.score is None:
            raise HTTPException(status_code=409, detail="referee stage did not run for this job")
        frame = body.frame if body.frame is not None else max(0, record.num_frames - 1)
        if frame >= max(record.num_frames, 1):
            raise HTTPException(status_code=400, detail="frame is past the end of the video")
        placed = sum(1 for r in record.rallies if r.end_frame <= frame)
        swap = ScoreCorrection(rally_index=placed, winner_before=None, winner_after=None,
                               at=utcnow(), kind="ends", frame=frame)  # fmt: skip
        before = record.score.model_copy(deep=True)
        apply_corrections(record, [*record.score.corrections, swap], job.start_score)
        if changes_finished_match(before, record.score):
            raise HTTPException(status_code=409, detail="the match is already won")
        log_decision(record, {"type": "ends", "frame": frame, "_game": before.game})
        _save_score(record, storage, jobs, job_id)
    return ScoreUpdate(score=record.score, rallies=record.rallies)


@router.post("/jobs/{job_id}/score/concede", response_model=ScoreUpdate)
def concede_match(
    job_id: str, body: ScoreConcedeIn, storage: StorageDep, jobs: JobsDep
) -> ScoreUpdate:
    """The other side retired: `winner` wins the match at `frame` (default: the end)."""
    job, path = _score_record(storage, jobs, job_id)
    with jobs.job_lock(job_id):
        job = _require_done(jobs, job_id)
        record = load_record(path.read_text(encoding="utf-8"))
        if record.score is None:
            raise HTTPException(status_code=409, detail="referee stage did not run for this job")
        if record.score.match_winner is not None:
            raise HTTPException(status_code=409, detail="the match is already won")
        frame = body.frame if body.frame is not None else max(0, record.num_frames - 1)
        if frame >= max(record.num_frames, 1):
            raise HTTPException(status_code=400, detail="frame is past the end of the video")
        before = sum(1 for r in record.rallies if r.end_frame <= frame)
        concede = ScoreCorrection(rally_index=before, winner_before=None,
                                  winner_after=body.winner, at=utcnow(), kind="concede",
                                  frame=frame)  # fmt: skip
        apply_corrections(record, [*record.score.corrections, concede], job.start_score)
        log_decision(
            record, {"type": "concede", "frame": frame, **body.model_dump(exclude_none=True)}
        )
        _save_score(record, storage, jobs, job_id)
    return ScoreUpdate(score=record.score, rallies=record.rallies)


@router.post("/jobs/{job_id}/score/service", response_model=ScoreUpdate)
def set_game_service(
    job_id: str, body: GameServiceIn, storage: StorageDep, jobs: JobsDep
) -> ScoreUpdate:
    """Doubles: name who serves and receives first in game 2 or 3 (D23); the service order
    and the service check then cover that game. Both null forgets the game's slots."""
    job, path = _score_record(storage, jobs, job_id)
    with jobs.job_lock(job_id):
        job = _require_done(jobs, job_id)
        if job.court != "doubles":
            raise HTTPException(status_code=409, detail="the service order is for doubles jobs")
        record = load_record(path.read_text(encoding="utf-8"))
        if record.score is None:
            raise HTTPException(status_code=409, detail="referee stage did not run for this job")
        kept = [g for g in record.score.game_service if g.game != body.game]
        if body.server_id is not None and body.receiver_id is not None:
            kept.append(GameService(game=body.game, server_id=body.server_id,
                                    receiver_id=body.receiver_id))  # fmt: skip
        record.score.game_service = sorted(kept, key=lambda g: g.game)
        apply_corrections(record, record.score.corrections, job.start_score)
        jobs.set_game_service(job_id, record.score.game_service)
        _save_score(record, storage, jobs, job_id)
    return ScoreUpdate(score=record.score, rallies=record.rallies)


@router.post("/jobs/{job_id}/score/undo", response_model=ScoreUpdate)
def undo_score(job_id: str, storage: StorageDep, jobs: JobsDep) -> ScoreUpdate:
    """Take back the newest decision: a correction, an award or a line-call override (D32)."""
    job, path = _score_record(storage, jobs, job_id)
    with jobs.job_lock(job_id):
        job = _require_done(jobs, job_id)
        record = load_record(path.read_text(encoding="utf-8"))
        job_dir = storage.job_dir(job_id)
        remaining = undo_last_decision(record, job.start_score, load_overrides(job_dir))
        if remaining is None:
            raise HTTPException(status_code=404, detail="no score change to undo")
        save_overrides(job_dir, remaining)
        log_decision(record, {"type": "undo"})
        _save_score(record, storage, jobs, job_id)
    return ScoreUpdate(score=record.score, rallies=record.rallies, line_calls=record.line_calls)


@router.patch("/jobs/{job_id}/line-calls/{call_id}", response_model=LineCallUpdate)
def override_line_call(
    job_id: str, call_id: int, body: LineCallOverrideBody, storage: StorageDep, jobs: JobsDep
) -> LineCallUpdate:
    """Confirm or override an automated call; the rally winner and score follow."""
    _require_done(jobs, job_id)
    path = _output_or_404(storage, jobs, job_id, "record")
    job_dir = storage.job_dir(job_id)
    with jobs.job_lock(job_id):
        job = _require_done(jobs, job_id)
        record = load_record(path.read_text(encoding="utf-8"))
        call = next((c for c in record.line_calls if c.id == call_id), None)
        if call is None:
            raise HTTPException(status_code=404, detail="line call not found")
        if record.score is None:
            raise HTTPException(status_code=409, detail="referee stage did not run for this job")
        if after_the_match(record, call.rally_index):
            # Refused before anything is saved, like an award after the deciding rally (D32).
            raise HTTPException(status_code=409, detail="the match is already won")
        # A log: the newest override per rally applies, so Undo can restore an earlier one.
        overrides = load_overrides(job_dir)
        overrides.append(
            LineCallOverrideIn(rally_index=call.rally_index, call=body.call, at=utcnow())
        )
        save_overrides(job_dir, overrides)
        apply_user_changes(record, job_dir, job.start_score)
        record.summary = build_summary(record)
        record.coaching = build_coaching(record, _feedback_config(jobs))
        log_decision(record, {"type": "override", "line_call_id": call_id, "call": body.call})
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
    # One question at a time per job, so parallel requests cannot get past the limit
    # (the history only grows once an answer is saved).
    # The mark expires on its own in case the stream is never started.
    answering: dict[str, float] = request.app.state.chat_answering

    def mark_answering() -> ClipRecord:
        # Under the job lock, like rerender's check: a re-render cannot be queued between
        # this status check and the mark. The history is read under it too, so it includes
        # an answer that was saved just before, and the limit counts that question.
        with jobs.job_lock(job_id):
            _require_done(jobs, job_id)
            record = load_record(path.read_text(encoding="utf-8"))
            asked = sum(m.role == "user" for m in (record.chat.messages if record.chat else []))
            if asked >= settings.chat_max_messages:
                raise HTTPException(
                    status_code=429, detail="question limit for this session reached"
                )
            if _chat_in_flight(request, job_id):
                raise HTTPException(status_code=409, detail="a question is already being answered")
            answering[job_id] = time.monotonic()
            return record

    record = await asyncio.to_thread(mark_answering)
    try:
        history = record.chat.messages if record.chat else []
        question = ChatMessage(role="user", text=body.message.strip(), at=utcnow())
        digest = build_digest(record, settings.chat_max_digest_chars)
        chat_settings = ChatSettings(model=settings.chat_model, effort=settings.chat_effort)
    except Exception:
        # The stream never starts, so its `finally` would not clear the mark: without this
        # the job refuses questions and re-renders until the mark times out.
        answering.pop(job_id, None)
        raise

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
        except (OSError, HTTPException) as exc:
            # Saving failed (the job was deleted mid-answer): say so instead of just stopping.
            error = {"type": "error", "status": 409, "detail": f"could not save the answer: {exc}"}
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


@router.put("/jobs/{job_id}/practice-goal", response_model=ClipRecord)
def update_practice_goal(
    job_id: str, body: PracticeGoal, storage: StorageDep, jobs: JobsDep
) -> ClipRecord:
    path = _output_or_404(storage, jobs, job_id, "record")
    with jobs.job_lock(job_id):
        job = _job_or_404(jobs, job_id)
        if job.status not in ("done", "failed"):
            raise HTTPException(status_code=409, detail="wait until the job has finished")
        record = load_record(path.read_text(encoding="utf-8"))
        try:
            set_goal(record, body, doubles=job.court == "doubles")
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        write_exports(record, storage.job_dir(job_id))
        return record
