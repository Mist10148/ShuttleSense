"""Fake camera: a video file replayed as live frames (T8.7).

Yields the binary messages the app sends on WS /live (12-byte header, then a JPEG), so
tests, the latency benchmark and `python -m shuttlesense.live_replay` exercise the same
path as a phone. Without a file it draws plain synthetic frames.
"""

from __future__ import annotations

import struct
import time
from collections.abc import Iterator
from pathlib import Path

import numpy as np

HEADER = struct.Struct("<Id")  # frame index, capture time in ms


def encode(frame: np.ndarray, index: int, ts_ms: float, quality: int = 80) -> bytes:
    import cv2

    ok, jpeg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if not ok:
        raise ValueError("could not encode frame")
    return HEADER.pack(index, ts_ms) + jpeg.tobytes()


def video_frames(path: Path, max_frames: int | None = None) -> Iterator[np.ndarray]:
    import cv2

    cap = cv2.VideoCapture(str(path))
    try:
        n = 0
        while max_frames is None or n < max_frames:
            ok, frame = cap.read()
            if not ok:
                return
            n += 1
            yield frame
    finally:
        cap.release()


def blank_frames(count: int, width: int = 640, height: int = 360) -> Iterator[np.ndarray]:
    """Grey frames with a moving square, so JPEGs differ like a real feed."""
    for i in range(count):
        frame = np.full((height, width, 3), 90, dtype=np.uint8)
        x = (i * 7) % (width - 20)
        frame[height // 2 : height // 2 + 20, x : x + 20] = 230
        yield frame


def replay(frames: Iterator[np.ndarray], fps: float, *, realtime: bool = True) -> Iterator[bytes]:
    """Frames as WS messages, paced at fps when realtime (as a camera would deliver them)."""
    start = time.perf_counter()
    for i, frame in enumerate(frames):
        if realtime:
            delay = start + i / fps - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        yield encode(frame, i, i * 1000 / fps)
