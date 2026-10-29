"""Video probing, normalized frame access and the io stage (F1, FR-1)."""

from __future__ import annotations

import math
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import numpy as np

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


def _open(path: Path):
    import cv2

    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise ValueError(f"cannot open video: {path.name}")
    return cap


def probe(path: Path) -> VideoInfo:
    """Read basic metadata without decoding the whole video.

    Width and height are as displayed: phone clips with 90/270 degree rotation metadata are
    reported rotated, matching the frames OpenCV returns (it applies the rotation itself).
    """
    import cv2

    cap = _open(path)
    try:
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
        if int(cap.get(cv2.CAP_PROP_ORIENTATION_META)) % 180 == 90:
            ok, frame = cap.read()
            if ok and frame.shape[:2] == (width, height) and width != height:
                width, height = height, width
        return VideoInfo(
            fps=float(cap.get(cv2.CAP_PROP_FPS)) or 30.0,
            width=width,
            height=height,
            num_frames=int(cap.get(cv2.CAP_PROP_FRAME_COUNT)),
        )
    finally:
        cap.release()


def check_duration(info: VideoInfo, max_duration_s: float) -> None:
    """Raise ValueError if the clip is longer than the FR-1 limit."""
    if max_duration_s and info.duration_s > max_duration_s:
        minutes = max_duration_s / 60
        raise ValueError(f"clip longer than {minutes:g} minutes ({info.duration_s:.0f} s)")


def read_frame(path: Path, index: int):
    """Return source frame `index` as a BGR array, or None if it does not exist."""
    import cv2

    cap = cv2.VideoCapture(str(path))
    try:
        cap.set(cv2.CAP_PROP_POS_FRAMES, index)
        ok, frame = cap.read()
        return frame if ok else None
    finally:
        cap.release()


def _count_frames(path: Path) -> int:
    cap = _open(path)
    try:
        n = 0
        while cap.grab():
            n += 1
        return n
    finally:
        cap.release()


class FrameReader:
    """Normalized frames: height <= target_height (even width) and fps <= max_fps.

    Frames are only ever scaled down. When the source fps is above max_fps, every k-th frame
    is kept with k = round(src_fps / max_fps), and fps becomes src_fps / k.
    Indices are normalized frame indices (what record.frames[] uses).
    """

    def __init__(self, path: Path, target_height: int = 720, max_fps: float = 30.0) -> None:
        self.path = Path(path)
        self.source = probe(self.path)
        src_frames = self.source.num_frames
        # Some containers (and VFR phone clips) report no frame count: count by decoding.
        if src_frames <= 0:
            src_frames = _count_frames(self.path)
        self.source_frames = src_frames
        src_fps = self.source.fps
        self.step = max(1, round(src_fps / max_fps)) if max_fps and src_fps > max_fps else 1
        self.fps = src_fps / self.step
        if target_height and self.source.height > target_height:
            scale = target_height / self.source.height
            self.height = int(target_height)
            self.width = max(2, int(round(self.source.width * scale / 2)) * 2)
        else:
            self.height, self.width = self.source.height, self.source.width
        self._len = math.ceil(src_frames / self.step)

    def __len__(self) -> int:
        return self._len

    @property
    def resized(self) -> bool:
        return (self.width, self.height) != (self.source.width, self.source.height)

    def _normalize(self, frame: np.ndarray) -> np.ndarray:
        import cv2

        if frame.shape[1] != self.width or frame.shape[0] != self.height:
            frame = cv2.resize(frame, (self.width, self.height), interpolation=cv2.INTER_AREA)
        return frame

    def __iter__(self) -> Iterator[tuple[int, np.ndarray]]:
        yield from self.frames(0, len(self))

    def frames(self, start: int, stop: int) -> Iterator[tuple[int, np.ndarray]]:
        """Yield (index, frame) for normalized indices start <= index < stop."""
        import cv2

        stop = min(stop, len(self))
        if start >= stop:
            return
        cap = _open(self.path)
        try:
            cap.set(cv2.CAP_PROP_POS_FRAMES, start * self.step)
            index, offset = start, 0
            while index < stop:
                if offset % self.step == 0:
                    ok, frame = cap.read()
                    if not ok:
                        break
                    yield index, self._normalize(frame)
                    index += 1
                elif not cap.grab():
                    break
                offset += 1
        finally:
            cap.release()

    def read(self, index: int) -> np.ndarray | None:
        """Frame at normalized `index`, or None past the end."""
        return next((f for _, f in self.frames(index, index + 1)), None)

    def batch(self, start: int, size: int) -> list[np.ndarray]:
        """Up to `size` consecutive frames starting at normalized `start`."""
        return [f for _, f in self.frames(start, start + size)]


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill normalized clip metadata and frames[], and expose ctx.reader to later stages."""
    cfg = ctx.stage_config("io")
    reader = FrameReader(
        ctx.video_path,
        target_height=cfg.get("target_height", 720),
        max_fps=cfg.get("max_fps", 30),
    )
    check_duration(reader.source, cfg.get("max_duration_s", 300))
    ctx.reader = reader
    record.fps = reader.fps
    record.width = reader.width
    record.height = reader.height
    record.num_frames = len(reader)
    record.frames = [Frame(frame=i) for i in range(len(reader))]
    ctx.progress(1.0)
    return record
