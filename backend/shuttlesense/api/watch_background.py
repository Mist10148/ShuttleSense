"""Background analysis for an independently playing uploaded video."""

from __future__ import annotations

import math
import threading
import time
from collections import deque
from typing import Annotated

import cv2
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from shuttlesense.api.live import HEADER, LiveBusy, _frames, _start_request
from shuttlesense.api.models import Job, utcnow
from shuttlesense.api.routes import get_storage, require_token
from shuttlesense.api.storage import Storage
from shuttlesense.io import FrameReader
from shuttlesense.stage import StageSkipped
from shuttlesense.strokes import registry
from shuttlesense.strokes.classify import load_classifier

router = APIRouter(dependencies=[Depends(require_token)])


class BackgroundStart(BaseModel):
    video_id: str
    court: str = "singles"
    corners: list[tuple[float, float]] | None = None


class Position(BaseModel):
    seconds: float = Field(ge=0, allow_inf_nan=False)


class BackgroundWatch:
    def __init__(self, state, source_id, reader, entry):
        self.state, self.source_id, self.reader, self.entry = state, source_id, reader, entry
        self.condition = threading.Condition()
        self.watched = 0.0
        self.target = None
        self.analyzed = 0
        self.latest_frame = None
        self.recent = deque(maxlen=64)
        self.error = None
        self.candidate_diagnostics = None
        self.shutdown_requested = False
        self.last_seen = time.monotonic()
        self.thread = threading.Thread(target=self.run, name="watch-background", daemon=True)

    def position(self, seconds, stop=False):
        with self.condition:
            if self.target is not None:
                return
            self.last_seen = time.monotonic()
            duration = len(self.reader) / self.reader.fps
            self.watched = max(self.watched, min(seconds, duration))
            if stop:
                self.target = self.watched
            self.state.jobs._update(
                self.entry.job_id, watch_position_s=self.watched, watch_target_s=self.target
            )
            self.condition.notify_all()

    def snapshot(self):
        with self.condition:
            job = self.state.jobs.get(self.entry.job_id)
            session = self.entry.session
            perception = getattr(session, "perception", None)
            perception = getattr(perception, "perception", perception)
            candidates = getattr(perception, "watch_candidates", None)
            diagnostics = ({"mode": candidates.mode, **candidates.stats}
                           if candidates is not None else self.candidate_diagnostics)
            return {
                "job_id": self.entry.job_id,
                "candidate_diagnostics": diagnostics,
                "watched_s": self.watched,
                "analyzed_s": self.analyzed / self.reader.fps,
                "target_s": self.target,
                "status": job.status if job else "cancelled",
                "stage": job.current_stage if job else None,
                "error": (job.error if job else None) or self.error,
                "frame": self.latest_frame,
                "events": list(self.recent),
            }

    def run(self):
        session = self.entry.session
        frames = iter(self.reader)
        last_update = 0.0
        try:
            while True:
                self.state.jobs.check_cancelled(self.entry.job_id)
                with self.condition:
                    if self.shutdown_requested:
                        raise RuntimeError("Server stopped before background analysis finished")
                    if self.target is None and time.monotonic() - self.last_seen > 15:
                        self.target = self.watched
                        self.state.jobs._update(self.entry.job_id, watch_target_s=self.target)
                    while self.analyzed >= math.ceil(self.watched * self.reader.fps - 1e-9):
                        if self.target is not None:
                            break
                        self.condition.wait(timeout=0.5)
                        if self.shutdown_requested:
                            raise RuntimeError("Server stopped before background analysis finished")
                        if time.monotonic() - self.last_seen > 15:
                            self.target = self.watched
                            self.state.jobs._update(self.entry.job_id, watch_target_s=self.target)
                            break
                        self.state.jobs.check_cancelled(self.entry.job_id)
                    target_count = min(
                        len(self.reader), math.ceil(self.watched * self.reader.fps - 1e-9)
                    )
                    done = self.target is not None and self.analyzed >= target_count
                if done:
                    break
                item = next(frames, None)
                if item is None:
                    break
                index, frame = item
                ok, jpeg = cv2.imencode(".jpg", frame)
                if not ok:
                    raise ValueError("Could not encode video frame")
                packet = HEADER.pack(index, index * 1000.0 / self.reader.fps) + jpeg.tobytes()
                events = _frames(session, [(packet, time.monotonic())])
                with self.condition:
                    self.analyzed = index + 1
                    for event in events:
                        if event.get("type") == "frame":
                            self.latest_frame = event
                        elif event.get("type") in (
                            "hit",
                            "rally",
                            "score",
                            "line_call",
                            "coaching",
                        ):
                            self.recent.append(event)
                    now = time.monotonic()
                    if now - last_update >= 1:
                        denominator = (
                            max(1, math.ceil(self.target * self.reader.fps - 1e-9))
                            if self.target is not None
                            else max(len(self.reader), 1)
                        )
                        self.state.jobs._update(
                            self.entry.job_id,
                            watch_analysis_s=self.analyzed / self.reader.fps,
                            progress=min(0.89, self.analyzed / denominator * 0.89),
                        )
                        last_update = now
            with self.state.jobs.job_lock(self.entry.job_id):
                self.state.jobs.check_cancelled(self.entry.job_id)
                if self.analyzed == 0:
                    raise ValueError("No video frames were watched.")
                self.state.jobs._update(
                    self.entry.job_id,
                    watch_analysis_s=self.analyzed / self.reader.fps,
                    current_stage="render",
                    progress=0.9,
                )
                if (
                    self.target is not None
                    and self.target >= len(self.reader) / self.reader.fps - 1 / self.reader.fps
                ):
                    session.request.name = "Watch & Analyze"
                self.state.live.finish(self.entry)
        except Exception as exc:
            self.error = str(exc) or "Background analysis failed"
            self.state.jobs.finish_outside(self.entry.job_id, error=self.error)
            with self.state.live.lock:
                removed = self.state.live.entries.pop(session.id, None)
            if removed:
                session.close()
                self.state.live.storage.delete_video(self.entry.video_id)
                self.state.live.state.jobs.gpu.release()
        finally:
            frames.close()
            perception = getattr(session.perception, "perception", session.perception)
            candidates = getattr(perception, "watch_candidates", None)
            if candidates is not None:
                with self.condition:
                    self.candidate_diagnostics = {"mode": candidates.mode, **candidates.stats}
            if hasattr(session.perception, "close"):
                session.perception.close()
            self.state.jobs.forget_cancelled(self.entry.job_id)
            # The registry keeps a small status snapshot; do not retain the full clip record.
            self.entry.session = None


def _sessions(request):
    return request.app.state.watch_background


@router.post("/watch/background", status_code=201)
def start_background(
    body: BackgroundStart, request: Request, storage: Annotated[Storage, Depends(get_storage)]
):
    with request.app.state.watch_background_lock:
        return _start_background(body, request, storage)


def _parallel_watch_enabled(setting, device: str) -> bool:
    """Auto mode uses concurrent models only for CUDA; booleans remain overrides."""
    return setting is True or (setting == "auto" and str(device).startswith("cuda"))


def _start_background(body: BackgroundStart, request: Request, storage: Storage):
    from shuttlesense.court import check_court_area, validate_corners

    state = request.app.state
    meta, source = storage.load_video_meta(body.video_id), storage.video_source(body.video_id)
    if meta is None or source is None:
        raise HTTPException(status_code=404, detail="Video not found")
    reader = FrameReader(
        source,
        target_height=int((state.jobs.config.get("live") or {}).get("target_height", 720)),
        max_fps=float((state.jobs.config.get("live") or {}).get("max_fps", 30)),
    )
    if not len(reader) or not reader.fps:
        raise HTTPException(status_code=400, detail="Video has no readable frames")
    corners = body.corners
    if corners is not None:
        try:
            validate_corners(corners)
            check_court_area(corners, (meta.width, meta.height))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        corners = [
            (x * reader.width / meta.width, y * reader.height / meta.height) for x, y in corners
        ]
    try:
        req = _start_request(
            {
                "fps": reader.fps,
                "width": reader.width,
                "height": reader.height,
                "court": body.court,
                "corners": corners,
            }
        )
        entry = state.live.create(req)
    except LiveBusy as exc:
        raise HTTPException(status_code=409, detail="Server is busy") from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    session = entry.session
    from shuttlesense.stream.perception import enable_watch_player_continuity

    enable_watch_player_continuity(session.perception)
    try:
        parallel = (state.jobs.config.get("watch") or {}).get("parallel_perception", False)
        use_parallel = _parallel_watch_enabled(parallel, state.jobs.device)
        if use_parallel and not state.live.fake:
            from shuttlesense.stream.watch_parallel import ParallelWatchPerception

            session.perception = ParallelWatchPerception(session.perception)
        session.live["scales"] = [1.0]
        session.request.name = "Watch & Analyze (partial)"
        session.analyzer.watch_stroke_guard = True
        cfg = session.config.get("stages", {}).get("strokes", {})
        name = registry.algorithm(cfg)
        try:
            _, checkpoint = load_classifier(registry.weights_path(cfg, name), state.jobs.device)
            session.analyzer.watch_checkpoint = checkpoint
            window = int(checkpoint.get("window_frames", cfg.get("window_frames", 32)))
            window_fps = checkpoint.get("window_fps")
            step = reader.fps / float(window_fps) if window_fps else 1.0
            session.analyzer.hit_lag = max(
                session.analyzer.hit_lag, math.ceil((window - 1 - window // 2) * step) + 1
            )
        except (StageSkipped, ImportError, OSError, ValueError, KeyError):
            pass
        job = Job(
            id=entry.job_id,
            video_id=body.video_id,
            status="running",
            mode="live",
            court=req.court,
            current_stage="analysis",
            started_at=utcnow(),
            watch_position_s=0.0,
            watch_analysis_s=0.0,
        )
        state.jobs.add(job)
        worker = BackgroundWatch(state, body.video_id, reader, entry)
        _sessions(request)[entry.job_id] = worker
        worker.thread.start()
    except Exception:
        with state.live.lock:
            state.live.entries.pop(session.id, None)
        session.close()
        if hasattr(session.perception, "close"):
            session.perception.close()
        state.jobs.gpu.release()
        raise
    return {
        "job_id": entry.job_id,
        "fps": reader.fps,
        "frames": len(reader),
        "width": reader.width,
        "height": reader.height,
        "stages": session.perception.available,
    }


@router.get("/watch/background/{job_id}")
def background_status(job_id: str, request: Request):
    worker = _sessions(request).get(job_id)
    if worker is None:
        raise HTTPException(status_code=404, detail="Watch session not found")
    return worker.snapshot()


@router.post("/watch/background/{job_id}/position")
def background_position(job_id: str, body: Position, request: Request):
    worker = _sessions(request).get(job_id)
    if worker is None:
        raise HTTPException(status_code=404, detail="Watch session not found")
    worker.position(body.seconds)
    return worker.snapshot()


@router.post("/watch/background/{job_id}/stop")
def background_stop(job_id: str, body: Position, request: Request):
    worker = _sessions(request).get(job_id)
    if worker is None:
        raise HTTPException(status_code=404, detail="Watch session not found")
    worker.position(body.seconds, stop=True)
    return worker.snapshot()
