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


def _current_analysis_notes(data: dict) -> list[dict]:
    """Keep only feedback whose original automatic event is still present and unchanged."""
    fps = float(data.get("fps") or 0)
    originals = {e.get("id"): e for e in data.get("automatic_events", []) if e.get("id")}
    retained = {}
    for event in data.get("events", []):
        original = originals.get(event.get("id"))
        if (
            original
            and event.get("source") == "automatic"
            and event.get("stroke") == original.get("stroke")
            and abs(float(event.get("time_s", -1)) - float(original.get("time_s", -2))) < 1e-6
        ):
            retained[event["id"]] = event

    def keep(note):
        note_id = note.get("event_id")
        if note_id:
            event = retained.get(note_id)
            return (
                event is not None
                and note.get("stroke") == event.get("stroke")
                and note.get("time_s") is not None
                and abs(float(note["time_s"]) - float(event.get("time_s", -1))) < 1e-6
            )
        if fps <= 0 or note.get("time_s") is None:
            return False
        matches = [
            e
            for e in originals.values()
            if e.get("frame") is not None
            and round(float(note["time_s"]) * fps) == e["frame"]
            and note.get("stroke") == e.get("stroke")
        ]
        return len(matches) == 1 and matches[0].get("id") in retained

    return [note for note in data.get("analysis_notes", []) if keep(note)]


def _completed_practice(job_id: str, request: Request, storage):
    import json

    job = request.app.state.jobs.get(job_id)
    if job is None or job.mode != "practice":
        raise HTTPException(status_code=404, detail="session not found")
    if job.status != "done":
        raise HTTPException(status_code=409, detail="session is not complete")
    if not storage.output_path(job_id, "video").exists():
        raise HTTPException(status_code=409, detail="rendered video is not available")
    path = storage.output_path(job_id, "practice")
    if not path.exists():
        raise HTTPException(status_code=404, detail="practice result not found")
    before = path.stat().st_mtime_ns
    data = json.loads(path.read_text(encoding="utf-8"))
    after = path.stat().st_mtime_ns
    if before != after:
        raise HTTPException(status_code=409, detail="analysis changed; retry")
    return path, data, after


def _practice_report_inputs(data):
    from shuttlesense.practice.evidence import AttemptEvidence

    excluded = set(data.get("unobserved_indices", []))
    fps = float(data.get("fps") or 0)
    frame_count = data.get("processed_frames")

    def visible_time(item):
        seconds = item.get("time_s")
        if not isinstance(seconds, (int, float)) or seconds < 0:
            return False
        if not fps:
            return True
        frame = round(seconds * fps)
        return frame not in excluded and (frame_count is None or frame < frame_count)

    observations = [
        AttemptEvidence.model_validate(a)
        for a in data.get("observations", [])
        if visible_time({"time_s": a.get("moment_s")})
    ]
    events = [event for event in data.get("events", []) if visible_time(event)]
    notes = [note for note in _current_analysis_notes(data) if visible_time(note)]
    context = {
        "processed_frames": data.get("processed_frames"),
        "fps": data.get("fps"),
        "unobserved_frames": data.get("unobserved_frames", 0),
        "stopped_early": data.get("stopped_early", False),
    }
    return observations, events, notes, context


@router.get("/sessions/{job_id}/analysis")
async def practice_analysis(job_id: str, request: Request, storage: StorageDep):
    from shuttlesense.practice.report import create_practice_report

    _, data, _ = _completed_practice(job_id, request, storage)
    observations, events, notes, context = _practice_report_inputs(data)
    rules = await create_practice_report(
        observations, events=events, analysis_notes=notes, session_context=context
    )
    return {**data, "rules_report": rules.model_dump()}


async def _practice_report(job_id: str, request: Request, storage, refresh: bool = False):
    import asyncio
    import json

    from shuttlesense.atomic import atomic_write_text
    from shuttlesense.practice.report import PracticeReport, create_practice_report

    state = request.app.state
    if not hasattr(state, "practice_report_locks"):
        state.practice_report_locks = {}
    lock = state.practice_report_locks.setdefault(job_id, asyncio.Lock())
    async with lock:
        path, data, mtime = _completed_practice(job_id, request, storage)
        cache_path = storage.job_dir(job_id) / "practice_report.json"
        provider = state.coach_provider
        if not refresh:
            try:
                cached = json.loads(cache_path.read_text(encoding="utf-8"))
                report = PracticeReport.model_validate(cached["report"])
                if cached.get("version") == 8 and cached["source_mtime_ns"] == mtime:
                    return report.model_dump(), mtime
            except (OSError, ValueError, KeyError, TypeError):
                pass
        observations, visible_events, visible_notes, context = _practice_report_inputs(data)
        report = await create_practice_report(
            observations, provider, state.coach.retriever, visible_events, visible_notes, context
        )
        jobs = state.jobs
        with jobs.job_lock(job_id):
            current = jobs.get(job_id)
            if current is None or current.status != "done" or not path.exists():
                raise HTTPException(status_code=404, detail="session no longer available")
            if path.stat().st_mtime_ns != mtime:
                raise HTTPException(status_code=409, detail="analysis changed; retry the report")
            atomic_write_text(
                cache_path,
                json.dumps(
                    {
                        "version": 8,
                        "source_mtime_ns": mtime,
                        "report": report.model_dump(),
                    }
                ),
            )
        return report.model_dump(), mtime


@router.get("/sessions/{job_id}/report")
async def practice_report(job_id: str, request: Request, storage: StorageDep):
    report, _ = await _practice_report(job_id, request, storage)
    return report


@router.post("/sessions/{job_id}/report")
async def refresh_practice_report(job_id: str, request: Request, storage: StorageDep):
    report, _ = await _practice_report(job_id, request, storage, refresh=True)
    return report


@router.get("/sessions/{job_id}/result")
async def practice_result(job_id: str, request: Request, storage: StorageDep):
    report, version = await _practice_report(job_id, request, storage)
    _, data, current_version = _completed_practice(job_id, request, storage)
    if current_version != version:
        raise HTTPException(status_code=409, detail="analysis changed; retry the report")
    return {**data, "report": report}


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
                slot = data.get("selected_slot", "near")
                player = (
                    getattr(record.frames[frame].players, slot)
                    if slot and frame not in data.get("unobserved_indices", [])
                    else None
                )
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
        data["analysis_notes"] = _current_analysis_notes(data)
        atomic_write_text(path, json.dumps(data))
        (storage.job_dir(job_id) / "practice_report.json").unlink(missing_ok=True)
        return data
