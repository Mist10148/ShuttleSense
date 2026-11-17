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

from shuttlesense.atomic import partial_path, replace
from shuttlesense.config import BACKEND_DIR

log = logging.getLogger("uvicorn.error")

# Windows cannot replace the old video while a player has it open: wait for the player to
# let go rather than lose the render.
REPLACE_TIMEOUT_S = 15.0


def find_ffmpeg() -> str | None:
    """Use system FFmpeg, the optional local build, or imageio-ffmpeg's binary."""
    system = shutil.which("ffmpeg")
    if system:
        return system
    local = BACKEND_DIR / ".bin" / "ffmpeg.exe"
    if local.is_file():
        return str(local)
    try:
        import imageio_ffmpeg

        return imageio_ffmpeg.get_ffmpeg_exe()
    except (ImportError, OSError, RuntimeError):
        return None


def ffmpeg_command(
    out_path: Path, *, fps: float, size: tuple[int, int], crf: int, codec: str, exe: str
) -> list[str]:
    w, h = size
    quality = (
        ["-preset", "p4", "-rc", "vbr", "-cq", str(crf), "-b:v", "0"]
        if codec == "h264_nvenc"
        else ["-crf", str(crf)]
    )
    return [
        exe, "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}", "-r", f"{fps:.6g}", "-i", "-",
        "-an", "-c:v", codec, "-pix_fmt", "yuv420p", *quality,
        "-movflags", "+faststart", str(out_path),
    ]  # fmt: skip


def nvenc_available(exe: str, size: tuple[int, int] = (256, 256)) -> bool:
    """Check the actual encoder and driver, not just FFmpeg's compiled encoder list."""
    try:
        result = subprocess.run(
            [
                exe,
                "-hide_banner",
                "-loglevel",
                "error",
                "-f",
                "lavfi",
                "-i",
                f"color=size={size[0]}x{size[1]}:rate=1",
                "-frames:v",
                "1",
                "-c:v",
                "h264_nvenc",
                "-f",
                "null",
                "-",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )
        if result.returncode:
            log.warning(
                "NVENC unavailable; using libx264: %s",
                result.stderr.decode(errors="replace").strip()[:500],
            )
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired) as exc:
        log.warning("NVENC probe failed; using libx264: %s", exc)
        return False


class VideoWriter:
    """Context manager: write(frame_bgr) for each frame; the file is complete on exit.

    Frames go to a temp file that replaces `path` only on success, so a player streaming the
    previous render never sees a half-written video.

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
        self.exe = find_ffmpeg() if use_ffmpeg else None
        self.backend = "ffmpeg" if self.exe else "opencv"
        self.frames = 0
        self._proc: subprocess.Popen | None = None
        self._cv = None
        self._tmp = partial_path(self.path)

    def __enter__(self) -> VideoWriter:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.exe:
            if self.codec == "h264_nvenc" and not nvenc_available(self.exe, self.size):
                self.codec = "libx264"
            cmd = ffmpeg_command(
                self._tmp, fps=self.fps, size=self.size, crf=self.crf, codec=self.codec,
                exe=self.exe,
            )  # fmt: skip
            self._proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
            log.info("Video encoder: ffmpeg %s", self.codec)
        else:
            import cv2

            log.warning("ffmpeg not found: writing mp4v, which browsers may not play")
            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
            self._cv = cv2.VideoWriter(str(self._tmp), fourcc, self.fps, self.size)
            if not self._cv.isOpened():
                raise RuntimeError(f"OpenCV could not open {self._tmp} for writing")
        return self

    def write(self, frame: np.ndarray) -> None:
        if frame.shape[1] != self.size[0] or frame.shape[0] != self.size[1]:
            import cv2

            frame = cv2.resize(frame, self.size)
        if self._proc is not None:
            assert self._proc.stdin is not None
            try:
                self._proc.stdin.write(np.ascontiguousarray(frame, dtype=np.uint8).tobytes())
            except OSError as e:  # BrokenPipeError, or EINVAL on Windows: ffmpeg has exited
                code, err = self._finish_ffmpeg()
                raise RuntimeError(f"ffmpeg failed ({code}): {err or e}") from e
        elif self._cv is not None:
            self._cv.write(frame)
        self.frames += 1

    def _finish_ffmpeg(self) -> tuple[int, str]:
        """Close ffmpeg's input, always reap it, and return (exit code, last stderr lines)."""
        assert self._proc is not None
        try:
            if self._proc.stdin is not None:
                self._proc.stdin.close()
        except OSError:
            pass  # the pipe is already broken; wait() below still reaps the process
        err = self._proc.stderr.read().decode(errors="replace") if self._proc.stderr else ""
        return self._proc.wait(), err.strip()[-500:]

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        try:
            if self._proc is not None and self._proc.returncode is None:
                code, err = self._finish_ffmpeg()
                if code != 0 and exc_type is None:
                    raise RuntimeError(f"ffmpeg failed ({code}): {err}")
            if self._cv is not None:
                self._cv.release()
            if exc_type is None:
                replace(self._tmp, self.path, timeout_s=REPLACE_TIMEOUT_S)
        finally:
            self._tmp.unlink(missing_ok=True)
