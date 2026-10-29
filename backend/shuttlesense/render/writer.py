"""MP4 writer: H.264 through ffmpeg, OpenCV mp4v fallback (F7, FR-7).

Browsers and the app's player need H.264 + yuv420p; +faststart puts the index first so
playback and seeking start before the whole file is downloaded. Audio is not kept.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
from pathlib import Path
from types import TracebackType

import numpy as np

log = logging.getLogger(__name__)


def ffmpeg_command(
    out_path: Path, *, fps: float, size: tuple[int, int], crf: int, codec: str, exe: str
) -> list[str]:
    w, h = size
    return [
        exe, "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}", "-r", f"{fps:.6g}", "-i", "-",
        "-an", "-c:v", codec, "-pix_fmt", "yuv420p", "-crf", str(crf),
        "-movflags", "+faststart", str(out_path),
    ]  # fmt: skip


class VideoWriter:
    """Context manager: write(frame_bgr) for each frame; the file is complete on exit.

    `backend` is "ffmpeg" or "opencv" (when ffmpeg is missing or use_ffmpeg is False).
    """

    def __init__(
        self,
        path: Path,
        *,
        fps: float,
        size: tuple[int, int],
        crf: int = 23,
        codec: str = "libx264",
        use_ffmpeg: bool = True,
    ) -> None:
        self.path = Path(path)
        self.fps = fps
        self.size = (int(size[0]), int(size[1]))
        self.crf = crf
        self.codec = codec
        self.exe = shutil.which("ffmpeg") if use_ffmpeg else None
        self.backend = "ffmpeg" if self.exe else "opencv"
        self.frames = 0
        self._proc: subprocess.Popen | None = None
        self._cv = None

    def __enter__(self) -> VideoWriter:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.exe:
            cmd = ffmpeg_command(
                self.path, fps=self.fps, size=self.size, crf=self.crf, codec=self.codec,
                exe=self.exe,
            )  # fmt: skip
            self._proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
        else:
            import cv2

            log.warning("ffmpeg not found: writing mp4v, which browsers may not play")
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            self._cv = cv2.VideoWriter(str(self.path), fourcc, self.fps, self.size)
        return self

    def write(self, frame: np.ndarray) -> None:
        if frame.shape[1] != self.size[0] or frame.shape[0] != self.size[1]:
            import cv2

            frame = cv2.resize(frame, self.size)
        if self._proc is not None:
            assert self._proc.stdin is not None
            self._proc.stdin.write(np.ascontiguousarray(frame, dtype=np.uint8).tobytes())
        elif self._cv is not None:
            self._cv.write(frame)
        self.frames += 1

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        if self._proc is not None:
            assert self._proc.stdin is not None
            self._proc.stdin.close()
            stderr = self._proc.stderr.read().decode(errors="replace") if self._proc.stderr else ""
            code = self._proc.wait()
            if code != 0 and exc_type is None:
                raise RuntimeError(f"ffmpeg failed ({code}): {stderr.strip()[-500:]}")
        if self._cv is not None:
            self._cv.release()
