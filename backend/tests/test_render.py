from __future__ import annotations

import shutil
from pathlib import Path

import numpy as np
import pytest

from shuttlesense.render.writer import VideoWriter


def _frames(n: int, size: tuple[int, int] = (64, 48)):
    w, h = size
    for i in range(n):
        img = np.zeros((h, w, 3), dtype=np.uint8)
        img[:, : (i * 4) % w] = 200
        yield img


def _count(path: Path) -> int:
    import cv2

    cap = cv2.VideoCapture(str(path))
    n = 0
    while cap.read()[0]:
        n += 1
    cap.release()
    return n


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_writer_produces_playable_mp4(tmp_path: Path) -> None:
    out = tmp_path / "out.mp4"
    with VideoWriter(out, fps=25, size=(64, 48)) as writer:
        assert writer.backend == "ffmpeg"
        for img in _frames(12):
            writer.write(img)
    assert _count(out) == 12


def test_writer_opencv_fallback(tmp_path: Path) -> None:
    out = tmp_path / "out.mp4"
    with VideoWriter(out, fps=25, size=(64, 48), use_ffmpeg=False) as writer:
        assert writer.backend == "opencv"
        for img in _frames(8):
            writer.write(img)
    assert _count(out) == 8
