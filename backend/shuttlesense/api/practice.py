"""Player selection for single-player practice, independent of court calibration."""

from __future__ import annotations

import math
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field

from shuttlesense.api.routes import StorageDep, _video_or_404, require_token
from shuttlesense.io import read_frame
from shuttlesense.pose.estimator import load_detector
from shuttlesense.practice.pipeline import PracticeSetup
from shuttlesense.stage import StageSkipped

router = APIRouter(dependencies=[Depends(require_token)], prefix="/practice")


class PlayerCandidate(BaseModel):
    bbox: tuple[float, float, float, float]
    score: float


class PlayerCandidates(BaseModel):
    video_id: str
    frame: int
    width: int
    height: int
    candidates: list[PlayerCandidate]


@router.get("/videos/{video_id}/players", response_model=PlayerCandidates)
def practice_candidates(
    video_id: str,
    request: Request,
    storage: StorageDep,
    frame: Annotated[int, Query(ge=0)] = 0,
) -> PlayerCandidates:
    """Find selectable people on a source frame, without court-specific tracking."""
    if request.app.state.settings.fake_pipeline:
        raise HTTPException(status_code=503, detail="Player detection is unavailable in demo mode")
    info = _video_or_404(storage, video_id)
    source = storage.video_source(video_id)
    if source is None or (info.num_frames > 0 and frame >= info.num_frames):
        raise HTTPException(status_code=404, detail="frame not found")
    image = read_frame(source, frame)
    if image is None:
        raise HTTPException(status_code=404, detail="frame not found")
    jobs = request.app.state.jobs
    if not jobs.gpu.acquire(blocking=False):
        raise HTTPException(status_code=409, detail="Server is busy; try again")
    try:
        config = jobs.config.get("stages", {}).get("pose", {})
        detect = load_detector(
            config.get("backend", "rtmlib"), config.get("mode", "balanced"), jobs.device
        )
        people = detect(image)
    except (StageSkipped, ImportError, RuntimeError, OSError) as exc:
        raise HTTPException(status_code=503, detail="Player detection unavailable") from exc
    finally:
        jobs.gpu.release()
    candidates = []
    for p in people:
        x, y, w, h = p.bbox
        if (
            all(math.isfinite(v) for v in (x, y, w, h, p.score))
            and w > 0
            and h > 0
            and p.score >= config.get("min_person_score", 0.4)
        ):
            x0, y0 = max(0.0, x), max(0.0, y)
            x1, y1 = min(float(info.width), x + w), min(float(info.height), y + h)
            if x1 > x0 and y1 > y0:
                candidates.append(PlayerCandidate(bbox=(x0, y0, x1 - x0, y1 - y0), score=p.score))
    return PlayerCandidates(
        video_id=video_id, frame=frame, width=info.width, height=info.height, candidates=candidates
    )


class Selection(BaseModel):
    frame: int = Field(ge=0)
    bbox: tuple[float, float, float, float]


def _check_box(box, info):
    from shuttlesense.practice.pipeline import validate_bbox

    try:
        validate_bbox(box)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    x, y, w, h = box
    if x < 0 or y < 0 or x + w > info.width or y + h > info.height:
        raise HTTPException(status_code=422, detail="Selection must be inside the video frame")


@router.post("/sessions", status_code=202)
def start_practice(body: PracticeSetup, request: Request, storage: StorageDep):
    from shuttlesense.api.jobs import VideoGone
    from shuttlesense.api.models import Job
    from shuttlesense.api.storage import new_id
    from shuttlesense.practice.pipeline import PracticeAnalyzer

    if request.app.state.settings.fake_pipeline:
        raise HTTPException(status_code=503, detail="Practice analysis is unavailable in demo mode")
    info = _video_or_404(storage, body.video_id)
    _check_box(body.selected_bbox, info)
    try:
        PracticeAnalyzer(body, info.fps, info.num_frames)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    job = Job(
        id=new_id(), video_id=body.video_id, mode="practice", practice_setup=body.model_dump()
    )
    try:
        return request.app.state.jobs.submit(job)
    except VideoGone as exc:
        raise HTTPException(status_code=404, detail="video not found") from exc


@router.post("/sessions/{job_id}/selection", status_code=202)
def resume_practice(job_id: str, body: Selection, request: Request, storage: StorageDep):
    from shuttlesense.api.jobs import JobBusy

    jobs = request.app.state.jobs
    job = jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="session not found")
    info = _video_or_404(storage, job.video_id)
    _check_box(body.bbox, info)
    if info.num_frames > 0 and body.frame >= info.num_frames:
        raise HTTPException(status_code=422, detail="selection frame is outside the video")
    try:
        return jobs.resume_practice(job_id, body.frame, body.bbox)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="session not found") from exc
    except JobBusy as exc:
        raise HTTPException(status_code=409, detail="session is not waiting for selection") from exc
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@router.get("/sessions/{job_id}")
def practice_session(job_id: str, request: Request):
    job = request.app.state.jobs.get(job_id)
    if job is None or job.mode != "practice":
        raise HTTPException(status_code=404, detail="session not found")
    return {
        **job.model_dump(mode="json"),
        "preview": request.app.state.jobs.practice_preview(job_id),
        "control": request.app.state.jobs.practice_control_state(job_id),
    }


@router.post("/sessions/{job_id}/control/{action}")
def control_practice(job_id: str, action: Literal["pause", "resume", "stop"], request: Request):
    from shuttlesense.api.jobs import JobBusy

    try:
        return request.app.state.jobs.practice_control(job_id, action)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="session not found") from exc
    except JobBusy as exc:
        raise HTTPException(status_code=409, detail="session cannot be controlled now") from exc


@router.get("/sessions/{job_id}/result")
async def practice_result(job_id: str, request: Request, storage: StorageDep):
    import json

    from shuttlesense.atomic import atomic_write_text
    from shuttlesense.practice.evidence import AttemptEvidence
    from shuttlesense.practice.report import PracticeReport, create_practice_report

    job = request.app.state.jobs.get(job_id)
    if job is None or job.mode != "practice":
        raise HTTPException(status_code=404, detail="session not found")
    if job.status != "done":
        raise HTTPException(status_code=409, detail="session is not complete")
    path = storage.output_path(job_id, "practice")
    if not path.exists():
        raise HTTPException(status_code=404, detail="practice result not found")
    data = json.loads(path.read_text(encoding="utf-8"))
    mtime = path.stat().st_mtime_ns
    cache_path = storage.job_dir(job_id) / "practice_report.json"
    provider = request.app.state.coach_provider
    try:
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        report = PracticeReport.model_validate(cached["report"])
        if (
            cached.get("version") == 3
            and cached["source_mtime_ns"] == mtime
            and not (provider is not None and report.generated_by == "rules" and report.evidence)
        ):
            return {**data, "report": report.model_dump()}
    except (OSError, ValueError, KeyError, TypeError):
        pass
    observations = [AttemptEvidence.model_validate(a) for a in data["observations"]]
    report = await create_practice_report(
        observations,
        provider,
        request.app.state.coach.retriever,
        data.get("events", []),
        data.get("analysis_notes", []),
    )
    # A failed provider call can be retried, and deleted/changed jobs must not be recreated.
    jobs = request.app.state.jobs
    with jobs.job_lock(job_id):
        current = jobs.get(job_id)
        if (
            current is not None
            and current.status == "done"
            and path.exists()
            and path.stat().st_mtime_ns == mtime
            and not (provider is not None and report.generated_by == "rules" and report.evidence)
        ):
            atomic_write_text(
                cache_path,
                json.dumps({"version": 3, "source_mtime_ns": mtime, "report": report.model_dump()}),
            )
    return {**data, "report": report.model_dump()}


class PracticeEvent(BaseModel):
    id: str = Field(min_length=1, max_length=80)
    time_s: float = Field(ge=0, allow_inf_nan=False)
    stroke: Literal["clear", "smash", "drop", "net_shot", "lift", "serve"] | None = None
    source: Literal["automatic", "manual"]
    confirmed: bool = False
    confidence: float | None = Field(default=None, ge=0, le=1, allow_inf_nan=False)
    model: Literal["cnn"] | None = None


class PracticeEvents(BaseModel):
    events: list[PracticeEvent] = Field(max_length=500)


@router.put("/sessions/{job_id}/events")
def update_events(job_id: str, body: PracticeEvents, request: Request, storage: StorageDep):
    """Save confirmed or corrected moments and invalidate the cached report."""
    import json

    from shuttlesense.atomic import atomic_write_text
    from shuttlesense.practice.evidence import assess_attempt
    from shuttlesense.schema import ClipRecord

    jobs = request.app.state.jobs
    with jobs.job_lock(job_id):
        job = jobs.get(job_id)
        if job is None or job.mode != "practice":
            raise HTTPException(status_code=404, detail="session not found")
        if job.status != "done":
            raise HTTPException(status_code=409, detail="session is not complete")
        path = storage.output_path(job_id, "practice")
        frames_path = storage.job_dir(job_id) / "practice_frames.json"
        if not path.exists() or not frames_path.exists():
            raise HTTPException(
                status_code=409, detail="Event editing is unavailable for this older session"
            )
        data = json.loads(path.read_text(encoding="utf-8"))
        record = ClipRecord.model_validate_json(frames_path.read_text(encoding="utf-8"))
        if len({event.id for event in body.events}) != len(body.events):
            raise HTTPException(status_code=422, detail="event ids must be distinct")
        observations = []
        events = []
        automatic = {event["id"]: event for event in data.get("automatic_events", [])}
        for event in sorted(body.events, key=lambda event: event.time_s):
            frame = round(event.time_s * record.fps)
            if frame < 0 or frame >= len(record.frames):
                raise HTTPException(status_code=422, detail="event time is outside the video")
            entry = event.model_dump()
            entry["frame"] = frame
            if event.source == "automatic":
                original = automatic.get(event.id)
                if original is None or abs(event.time_s - original["time_s"]) > 1e-6:
                    raise HTTPException(status_code=422, detail="invalid automatic event reference")
                if event.stroke == original["stroke"]:
                    entry["confidence"], entry["model"] = original["confidence"], original["model"]
                else:
                    entry["source"], entry["confidence"], entry["model"] = "manual", None, None
            else:
                entry["confidence"], entry["model"] = None, None
            events.append(entry)
            valid_automatic = entry["source"] == "automatic" and entry["model"] == "cnn"
            if (event.confirmed or valid_automatic) and event.stroke in ("clear", "smash", "drop"):
                player = record.frames[frame].players.near
                observations.append(
                    assess_attempt(
                        player,
                        event.stroke,
                        data["setup"]["arm"],
                        event.time_s,
                        provenance="automatic"
                        if valid_automatic and not event.confirmed
                        else "user_marked",
                    ).model_dump()
                )
        data["events"] = events
        data["observations"] = observations
        atomic_write_text(path, json.dumps(data))
        (storage.job_dir(job_id) / "practice_report.json").unlink(missing_ok=True)
        return data
