"""On-disk layout for uploads and job outputs (docs/ARCHITECTURE.md §3).

storage/videos/<video_id>/source.<ext> + meta.json
storage/jobs/<job_id>/job.json, record.json, annotated.mp4, summary.json, hits.csv
"""

from __future__ import annotations

import shutil
import uuid
from pathlib import Path

from shuttlesense.api.models import Job, VideoInfoOut

OUTPUT_FILES = {
    "record": "record.json",
    "video": "annotated.mp4",
    "summary": "summary.json",
    "hits_csv": "hits.csv",
}


def new_id() -> str:
    return uuid.uuid4().hex[:12]


class Storage:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.videos_dir = root / "videos"
        self.jobs_dir = root / "jobs"
        self.videos_dir.mkdir(parents=True, exist_ok=True)
        self.jobs_dir.mkdir(parents=True, exist_ok=True)

    # Videos -----------------------------------------------------------------

    def video_dir(self, video_id: str) -> Path:
        return self.videos_dir / video_id

    def video_source(self, video_id: str) -> Path | None:
        matches = sorted(self.video_dir(video_id).glob("source.*"))
        return matches[0] if matches else None

    def save_video_meta(self, info: VideoInfoOut) -> None:
        (self.video_dir(info.id) / "meta.json").write_text(info.model_dump_json(), encoding="utf-8")

    def load_video_meta(self, video_id: str) -> VideoInfoOut | None:
        path = self.video_dir(video_id) / "meta.json"
        if not path.exists():
            return None
        return VideoInfoOut.model_validate_json(path.read_text(encoding="utf-8"))

    def delete_video(self, video_id: str) -> None:
        shutil.rmtree(self.video_dir(video_id), ignore_errors=True)

    # Jobs -------------------------------------------------------------------

    def job_dir(self, job_id: str) -> Path:
        return self.jobs_dir / job_id

    def output_path(self, job_id: str, key: str) -> Path:
        return self.job_dir(job_id) / OUTPUT_FILES[key]

    def save_job(self, job: Job) -> None:
        d = self.job_dir(job.id)
        d.mkdir(parents=True, exist_ok=True)
        (d / "job.json").write_text(job.model_dump_json(), encoding="utf-8")

    def load_jobs(self) -> list[Job]:
        jobs = []
        for path in self.jobs_dir.glob("*/job.json"):
            try:
                jobs.append(Job.model_validate_json(path.read_text(encoding="utf-8")))
            except ValueError:
                continue
        return jobs

    def delete_job(self, job_id: str) -> None:
        shutil.rmtree(self.job_dir(job_id), ignore_errors=True)
