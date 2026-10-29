from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from shuttlesense.atomic import atomic_open, atomic_write_text, partial_path
from shuttlesense.render.writer import VideoWriter


def test_failed_write_keeps_the_old_file(tmp_path: Path) -> None:
    target = tmp_path / "record.json"
    atomic_write_text(target, '{"v": 1}')
    with pytest.raises(RuntimeError), atomic_open(target) as f:
        f.write('{"v": ')
        raise RuntimeError("crashed mid-write")
    assert target.read_text() == '{"v": 1}'
    assert list(tmp_path.iterdir()) == [target]


def test_video_appears_only_when_complete(tmp_path: Path) -> None:
    target = tmp_path / "annotated.mp4"
    frame = np.zeros((32, 48, 3), np.uint8)
    with VideoWriter(target, fps=10, size=(48, 32), use_ffmpeg=False) as writer:
        writer.write(frame)
        assert not target.exists() and partial_path(target).exists()
    assert target.stat().st_size > 0 and not partial_path(target).exists()

    with pytest.raises(ValueError), VideoWriter(target, fps=10, size=(48, 32), use_ffmpeg=False):
        raise ValueError("render failed")
    assert target.stat().st_size > 0 and not partial_path(target).exists()
