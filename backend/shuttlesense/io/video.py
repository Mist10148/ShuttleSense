"""Video probing, frame access and the io stage (F1, FR-1)."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from shuttlesense.schema import ClipRecord, Frame
from shuttlesense.stage import StageContext

SUPPORTED_SUFFIXES = {".mp4", ".mov", ".avi"}


@dataclass(frozen=True)
class VideoInfo:
    fps: float
    width: int
    height: int
    num_frames: int

    @property
    def duration_s(self) -> float:
        return self.num_frames / self.fps if self.fps else 0.0


def probe(path: Path) -> VideoInfo:
    """Read basic metadata without decoding the whole video."""
    import cv2

    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise ValueError(f"cannot open video: {path.name}")
    try:
        return VideoInfo(
            fps=float(cap.get(cv2.CAP_PROP_FPS)) or 30.0,
            width=int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
            height=int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
            num_frames=int(cap.get(cv2.CAP_PROP_FRAME_COUNT)),
        )
    finally:
        cap.release()


def read_frame(path: Path, index: int):
    """Return frame `index` as a BGR array, or None if it does not exist."""
    import cv2

    cap = cv2.VideoCapture(str(path))
    try:
        cap.set(cv2.CAP_PROP_POS_FRAMES, index)
        ok, frame = cap.read()
        return frame if ok else None
    finally:
        cap.release()


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill clip metadata and the frame index.

    TODO(T2.1): normalize resolution (720p) and frame rate, enforce the 5-minute limit,
    and expose a frame iterator for later stages.
    """
    info = probe(ctx.video_path)
    record.fps = info.fps
    record.width = info.width
    record.height = info.height
    record.num_frames = info.num_frames
    record.frames = [Frame(frame=i) for i in range(info.num_frames)]
    ctx.progress(1.0)
    return record
