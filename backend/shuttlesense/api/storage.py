"""On-disk layout for uploads and job outputs (docs/ARCHITECTURE.md §3).

storage/videos/<video_id>/source.<ext> + meta.json
storage/jobs/<job_id>/job.json, record.json, annotated.mp4, summary.json, hits.csv, rallies.csv
"""

from __future__ import annotations

import logging
import re
import shutil
import uuid
from pathlib import Path

from shuttlesense.api.models import Job, VideoInfoOut
from shuttlesense.atomic import atomic_write_text

log = logging.getLogger(__name__)

OUTPUT_FILES = {
    "record": "record.json",
    "video": "annotated.mp4",
    "summary": "summary.json",
    "hits_csv": "hits.csv",
    "rallies_csv": "rallies.csv",
}


_ID = re.compile(r"[0-9a-f]{12}")


def new_id() -> str:
    return uuid.uuid4().hex[:12]


def is_id(value: str) -> bool:
    """True for ids made by new_id. Anything else (e.g. "..\\x") must never become a path."""
    return _ID.fullmatch(value) is not None


class Storage:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.videos_dir = root / "videos"
        self.jobs_dir = root / "jobs"
        self.videos_dir.mkdir(parents=True, exist_ok=True)
        self.jobs_dir.mkdir(parents=True, exist_ok=True)

    # Videos -----------------------------------------------------------------

    def video_dir(self, video_id: str) -> Path:
        if not is_id(video_id):
            raise ValueError(f"invalid video id: {video_id!r}")
        return self.videos_dir / video_id

    def video_source(self, video_id: str) -> Path | None:
        if not is_id(video_id):
            return None
        matches = sorted(self.video_dir(video_id).glob("source.*"))
        return matches[0] if matches else None

    def save_video_meta(self, info: VideoInfoOut) -> None:
        atomic_write_text(self.video_dir(info.id) / "meta.json", info.model_dump_json())

    def load_video_meta(self, video_id: str) -> VideoInfoOut | None:
        if not is_id(video_id):
            return None
        path = self.video_dir(video_id) / "meta.json"
        if not path.exists():
            return None
        return VideoInfoOut.model_validate_json(path.read_text(encoding="utf-8"))

    def delete_video(self, video_id: str) -> None:
        """Remove an upload. meta.json goes first: while a running job still has the source
        open (Windows cannot delete it then), the video is already gone for the API, and
        the job worker removes the rest once the job stops (JobManager)."""
        if not is_id(video_id):
            return
        d = self.video_dir(video_id)
        (d / "meta.json").unlink(missing_ok=True)
        shutil.rmtree(d, ignore_errors=True)
        if d.exists():
            log.info("video %s is still in use; it is removed when its job stops", video_id)

    def video_deleted(self, video_id: str) -> bool:
        """True if delete_video ran but could not remove every file."""
        d = self.video_dir(video_id)
        return d.exists() and not (d / "meta.json").exists()

    # Jobs -------------------------------------------------------------------

    def job_dir(self, job_id: str) -> Path:
        if not is_id(job_id):
            raise ValueError(f"invalid job id: {job_id!r}")
        return self.jobs_dir / job_id

    def output_path(self, job_id: str, key: str) -> Path:
        return self.job_dir(job_id) / OUTPUT_FILES[key]

    def save_job(self, job: Job) -> None:
        d = self.job_dir(job.id)
        d.mkdir(parents=True, exist_ok=True)
        atomic_write_text(d / "job.json", job.model_dump_json())

    def load_jobs(self) -> list[Job]:
        jobs = []
        for path in self.jobs_dir.glob("*/job.json"):
            try:
                jobs.append(Job.model_validate_json(path.read_text(encoding="utf-8")))
            except (OSError, ValueError) as exc:  # one bad file must not stop the server
                log.warning("skipping unreadable %s: %s", path, exc)
        return jobs

    def delete_job(self, job_id: str) -> None:
        if not is_id(job_id):
            return
        shutil.rmtree(self.job_dir(job_id), ignore_errors=True)
