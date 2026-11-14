from __future__ import annotations

import os
from pathlib import Path

import numpy as np
import pytest

from shuttlesense import atomic
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


def _lock_target(monkeypatch: pytest.MonkeyPatch, failures: int) -> list[float]:
    """os.replace fails `failures` times, as on Windows while a reader has the target open.
    Returns the list the retry delays are recorded in, instead of being slept."""
    real_replace, calls, sleeps = os.replace, [], []

    def locked(src, dst) -> None:
        calls.append(dst)
        if len(calls) <= failures:
            raise PermissionError(13, "the file is in use")
        real_replace(src, dst)

    monkeypatch.setattr(atomic.os, "replace", locked)
    monkeypatch.setattr(atomic.time, "sleep", sleeps.append)
    return sleeps


def test_small_files_retry_a_locked_target_briefly(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    target = tmp_path / "record.json"
    atomic_write_text(target, '{"v": 1}')
    sleeps = _lock_target(monkeypatch, failures=5)
    atomic_write_text(target, '{"v": 2}')
    assert target.read_text() == '{"v": 2}' and len(sleeps) == 5

    sleeps = _lock_target(monkeypatch, failures=10_000)
    with pytest.raises(PermissionError):
        atomic_write_text(target, '{"v": 3}')
    assert sum(sleeps) < 3  # seconds
    assert target.read_text() == '{"v": 2}' and list(tmp_path.iterdir()) == [target]


def test_video_waits_longer_for_a_player_to_release_the_old_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    target = tmp_path / "annotated.mp4"
    frame = np.zeros((32, 48, 3), np.uint8)
    sleeps = _lock_target(monkeypatch, failures=100)  # 10 s of a player streaming the video
    with VideoWriter(target, fps=10, size=(48, 32), use_ffmpeg=False) as writer:
        writer.write(frame)
    assert target.stat().st_size > 0 and len(sleeps) == 100

    target.unlink()
    sleeps = _lock_target(monkeypatch, failures=10_000)
    with (
        pytest.raises(PermissionError),
        VideoWriter(target, fps=10, size=(48, 32), use_ffmpeg=False) as writer,
    ):
        writer.write(frame)
    assert 14 < sum(sleeps) <= 15  # seconds
    assert not target.exists() and not partial_path(target).exists()
