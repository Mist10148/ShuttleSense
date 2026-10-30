"""Job registry and a single GPU worker thread (docs/ARCHITECTURE.md, job lifecycle)."""

from __future__ import annotations

import itertools
import json
import logging
import queue
import threading
from collections.abc import Callable
from pathlib import Path
from typing import Any

from shuttlesense.api.models import Job, JobOutputs, StageState, utcnow
from shuttlesense.api.storage import OUTPUT_FILES, Storage
from shuttlesense.atomic import atomic_write_text
from shuttlesense.pipeline import STAGE_NAMES, run_pipeline

# Signature of run_pipeline, injectable for tests.
PipelineFn = Callable[..., Any]

log = logging.getLogger(__name__)


# Expected share of wall time per stage; overridable with stages.<name>.weight.
DEFAULT_STAGE_WEIGHTS = {"tracking": 4.0, "pose": 4.0, "render": 2.0}


class JobCancelled(Exception):
    pass


class JobBusy(Exception):
    """The job is queued or running, so it cannot be changed yet."""


class JobManager:
    """Keeps jobs in memory (mirrored to job.json) and runs them one at a time."""

    def __init__(
        self,
        storage: Storage,
        *,
        config: dict[str, Any],
        device: str,
        pipeline: PipelineFn = run_pipeline,
    ) -> None:
        self.storage = storage
        self.config = config
        self.device = device
        self.pipeline = pipeline
        self._jobs: dict[str, Job] = {j.id: j for j in storage.load_jobs()}
        self._cancelled: set[str] = set()
        self._queue: queue.Queue[str | None] = queue.Queue()
        self._lock = threading.Lock()
        self._job_locks: dict[str, threading.Lock] = {}
        self._worker: threading.Thread | None = None
        # One GPU: a job runs only while no live session holds it, and the other way round.
        self.gpu = threading.Lock()
        # FIFO order of the queue, for queue_position (created_at is wrong after a re-render).
        self._enqueued: dict[str, int] = {}
        self._ticket = itertools.count()

        # Jobs interrupted by a server restart cannot resume. An interrupted re-render still
        # has the outputs of its last run (they are only ever replaced whole), so it is done,
        # with the overlays and stage states of that run.
        for job in self._jobs.values():
            if job.status in ("queued", "running"):
                if self.has_outputs(job.id):
                    job.status, job.progress, job.current_stage = "done", 1.0, None
                    job.finished_at = utcnow()
                    job.stages = [
                        StageState(name=n, status="done", progress=1.0) for n in STAGE_NAMES
                    ]
                    self._restore_previous(job, stages=True)
                else:
                    job.status = "failed"
                    job.error = "server restarted before the job finished"
                storage.save_job(job)

    # Lifecycle --------------------------------------------------------------

    def start(self) -> None:
        if self._worker is None:
            self._worker = threading.Thread(
                target=self._run_forever, daemon=True, name="job-worker"
            )
            self._worker.start()

    def stop(self) -> None:
        if self._worker is not None:
            self._queue.put(None)
            self._worker.join(timeout=5)
            self._worker = None

    # Public API -------------------------------------------------------------

    def submit(self, job: Job) -> Job:
        job.stages = [StageState(name=n) for n in STAGE_NAMES]
        with self._lock:
            self._jobs[job.id] = job
            self.storage.save_job(job)
            self._enqueued[job.id] = next(self._ticket)
        self._queue.put(job.id)
        return self.get(job.id)

    def rerender(self, job_id: str, overlays: list[str]) -> Job | None:
        """Queue a finished job again with new overlays. The pipeline reuses its stage cache
        in the job folder, so only io and render actually run.

        Returns None if the job is gone. Raises JobBusy if it is queued or running."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            if job.status in ("queued", "running"):
                raise JobBusy(job_id)
            previous = self.storage.previous_path(job_id)
            if not previous.exists():  # after a failed re-render it still holds the last good run
                state = {
                    "overlays": job.overlays,
                    "stages": [s.model_dump() for s in job.stages],
                }
                atomic_write_text(previous, json.dumps(state))
            job.overlays = list(overlays)
            job.status = "queued"
            job.progress = 0.0
            job.error = None
            job.current_stage = None
            job.started_at = None
            job.finished_at = None
            job.stages = [StageState(name=n) for n in STAGE_NAMES]
            self.storage.save_job(job)
            self._enqueued[job_id] = next(self._ticket)
        self._queue.put(job_id)
        return self.get(job_id)

    def _restore_previous(self, job: Job, *, stages: bool) -> None:
        """Put back what rerender() saved, so the job describes the outputs on disk."""
        path = self.storage.previous_path(job.id)
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        job.overlays = list(state.get("overlays", job.overlays))
        if stages and state.get("stages"):
            job.stages = [StageState.model_validate(s) for s in state["stages"]]

    def has_outputs(self, job_id: str) -> bool:
        """True once a run has finished, so the job can be re-rendered even if a later
        re-render failed."""
        return self.storage.output_path(job_id, "record").exists()

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            if job.status == "queued":
                waiting = [j for j in self._jobs.values() if j.status == "queued"]
                waiting.sort(key=lambda j: self._enqueued.get(j.id, -1))
                job.queue_position = waiting.index(job)
            else:
                job.queue_position = None
            return job.model_copy(deep=True)

    def list(self, limit: int = 50) -> list[Job]:
        with self._lock:
            ids = sorted(self._jobs, key=lambda i: self._jobs[i].created_at, reverse=True)
        return [j for j in (self.get(i) for i in ids[:limit]) if j is not None]

    def cancel_or_delete(self, job_id: str) -> bool:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return False
            if job.status in ("queued", "running"):
                self._cancelled.add(job_id)
                job.status = "cancelled"
                job.finished_at = utcnow()
            del self._jobs[job_id]
            self._enqueued.pop(job_id, None)
        self.storage.delete_job(job_id)
        return True

    def delete_for_video(self, video_id: str) -> None:
        with self._lock:
            ids = [j.id for j in self._jobs.values() if j.video_id == video_id]
        for job_id in ids:
            self.cancel_or_delete(job_id)

    # Worker -----------------------------------------------------------------

    def _run_forever(self) -> None:
        while True:
            job_id = self._queue.get()
            if job_id is None:
                return
            try:
                self._run_one(job_id)
            except Exception:  # keep the worker alive (e.g. disk full while saving job.json)
                log.exception("job %s could not be run", job_id)
                try:
                    self._update(
                        job_id, status="failed", error="internal server error", finished_at=utcnow()
                    )
                except Exception:
                    log.exception("job %s could not be marked failed", job_id)
            finally:
                with self._lock:
                    self._cancelled.discard(job_id)

    def _update(self, job_id: str, **changes: Any) -> None:
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            for key, value in changes.items():
                setattr(job, key, value)
            self.storage.save_job(job)

    def job_lock(self, job_id: str) -> threading.Lock:
        """Lock for edits to one job's outputs (score corrections)."""
        with self._lock:
            return self._job_locks.setdefault(job_id, threading.Lock())

    def job_config(self, job: Job) -> dict[str, Any]:
        """Pipeline config plus this job's own inputs."""
        config = dict(self.config)
        if job.start_score is not None:
            config["start_score"] = job.start_score.model_dump()
        config["mode"] = job.mode
        return config

    def add(self, job: Job) -> Job:
        """Register a job made outside the queue (a saved live session)."""
        with self._lock:
            self._jobs[job.id] = job
            self.storage.save_job(job)
        return job

    def finish_outside(self, job_id: str, *, error: str | None = None) -> None:
        """Mark a job registered with add() done (or failed) once its outputs are written."""
        out_dir = self.storage.job_dir(job_id)
        outputs = {key: (out_dir / name).exists() for key, name in OUTPUT_FILES.items()}
        if error is not None:
            self._update(job_id, status="failed", error=error, finished_at=utcnow(),
                         current_stage=None, outputs=JobOutputs(**outputs))  # fmt: skip
            return
        stages = [StageState(name=n, status="done", progress=1.0) for n in STAGE_NAMES]
        self._update(
            job_id,
            status="done",
            progress=1.0,
            current_stage=None,
            finished_at=utcnow(),
            outputs=JobOutputs(**outputs),
            stages=stages,
        )

    def stage_weight(self, name: str) -> float:
        """Relative cost of a stage for overall progress (stages.<name>.weight)."""
        cfg = self.config.get("stages", {}).get(name, {})
        return float(cfg.get("weight", DEFAULT_STAGE_WEIGHTS.get(name, 0.2)))

    def _on_event(self, job_id: str, name: str, status: str, progress: float) -> None:
        if job_id in self._cancelled:
            raise JobCancelled
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                raise JobCancelled
            for stage in job.stages:
                if stage.name == name:
                    stage.status = status
                    stage.progress = progress
            if status == "running":
                job.current_stage = name
            active = [s for s in job.stages if s.status != "skipped"]
            total = sum(self.stage_weight(s.name) for s in active)
            if total:
                done = sum(
                    self.stage_weight(s.name) * (1.0 if s.status == "done" else s.progress)
                    for s in active
                )
                # Never move backwards, even when a stage reports a lower value.
                job.progress = max(job.progress, min(done / total, 1.0))

    def _run_one(self, job_id: str) -> None:
        job = self.get(job_id)
        with self._lock:
            self._enqueued.pop(job_id, None)
        if job is None or job.status != "queued":
            return
        source: Path | None = self.storage.video_source(job.video_id)
        if source is None:
            self._update(job_id, status="failed", error="video not found", finished_at=utcnow())
            return
        self._update(job_id, status="running", started_at=utcnow())
        out_dir = self.storage.job_dir(job_id)
        try:
            with self.gpu:
                self.pipeline(
                    source,
                    out_dir,
                    clip_id=job_id,
                    config=self.job_config(job),
                    court_corners_px=job.court_corners_px,
                    overlays=job.overlays,
                    referee_enabled=job.referee,
                    device=self.device,
                    on_event=lambda n, s, p: self._on_event(job_id, n, s, p),
                )
        except JobCancelled:
            self.storage.delete_job(job_id)
            return
        except Exception as exc:  # report any stage failure to the client
            log.exception("job %s failed", job_id)
            error = str(exc) or type(exc).__name__
            with self._lock:
                job_now = self._jobs.get(job_id)
                if job_now is not None:  # a failed re-render keeps the outputs of the last run
                    self._restore_previous(job_now, stages=False)
            self._update(job_id, status="failed", error=error, finished_at=utcnow())
            return
        finally:
            # DELETE /videos while this job ran: the source was open, so finish the delete.
            if self.storage.video_deleted(job.video_id):
                self.storage.delete_video(job.video_id)
        if self.get(job_id) is None:  # deleted while the last stage was finishing
            self.storage.delete_job(job_id)
            return
        outputs = {key: (out_dir / name).exists() for key, name in OUTPUT_FILES.items()}
        self.storage.previous_path(job_id).unlink(missing_ok=True)
        self._update(
            job_id,
            status="done",
            progress=1.0,
            current_stage=None,
            finished_at=utcnow(),
            outputs=JobOutputs(**outputs),
        )
