from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from shuttlesense.io import FrameReader, check_duration, probe
from shuttlesense.io import run as io_run
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext


def make_clip(path: Path, *, fps: float, size: tuple[int, int], frames: int) -> Path:
    import cv2

    w, h = size
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    for i in range(frames):
        frame = np.zeros((h, w, 3), dtype=np.uint8)
        frame[:, :, 1] = i % 256  # frame number encoded in the green channel
        writer.write(frame)
    writer.release()
    return path


def test_probe_reads_metadata(tiny_video: Path) -> None:
    info = probe(tiny_video)
    assert (info.width, info.height, info.num_frames) == (160, 90, 10)
    assert info.fps == pytest.approx(25.0)


def test_reader_downsamples_60_to_30fps(tmp_path: Path) -> None:
    clip = make_clip(tmp_path / "c60.mp4", fps=60, size=(64, 48), frames=20)
    reader = FrameReader(clip, target_height=720, max_fps=30)
    assert reader.step == 2 and reader.fps == pytest.approx(30.0)
    frames = list(reader)
    assert len(frames) == len(reader) == 10
    greens = [int(f[:, :, 1].mean().round()) for _, f in frames]
    assert greens == pytest.approx(list(range(0, 20, 2)), abs=3)
    assert int(reader.read(3)[:, :, 1].mean().round()) == pytest.approx(6, abs=3)
    assert len(reader.batch(8, 5)) == 2


def test_reader_resizes_to_target_height(tmp_path: Path) -> None:
    clip = make_clip(tmp_path / "big.mp4", fps=25, size=(320, 180), frames=3)
    reader = FrameReader(clip, target_height=90, max_fps=30)
    assert (reader.width, reader.height) == (160, 90) and reader.resized
    assert reader.read(0).shape == (90, 160, 3)
    small = FrameReader(clip, target_height=720, max_fps=30)
    assert (small.width, small.height) == (320, 180) and not small.resized


def test_reader_makes_odd_sizes_even(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # libx264 rejects odd sizes, e.g. 853x480 (16:9 at 480p); OpenCV cannot write such a test
    # clip, so the probe is faked.
    from shuttlesense.io import video

    odd = video.VideoInfo(fps=25.0, width=853, height=481, num_frames=3)
    monkeypatch.setattr(video, "probe", lambda _path: odd)
    reader = FrameReader(tmp_path / "odd.mp4", target_height=720, max_fps=30)
    assert (reader.width, reader.height) == (852, 480) and reader.resized
    assert reader._normalize(np.zeros((481, 853, 3), np.uint8)).shape == (480, 852, 3)


def test_rejects_clip_over_limit(tiny_video: Path, tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="longer than"):
        check_duration(probe(tiny_video), 0.2)
    ctx = StageContext(
        video_path=tiny_video,
        out_dir=tmp_path,
        config={"stages": {"io": {"max_duration_s": 0.2}}},
    )
    record = ClipRecord(clip_id="c", fps=0, width=0, height=0, num_frames=0)
    with pytest.raises(ValueError):
        io_run(record, ctx)


def test_io_stage_sets_reader(tiny_video: Path, tmp_path: Path) -> None:
    ctx = StageContext(video_path=tiny_video, out_dir=tmp_path)
    record = io_run(ClipRecord(clip_id="c", fps=0, width=0, height=0, num_frames=0), ctx)
    assert ctx.reader is not None and record.num_frames == len(ctx.reader) == len(record.frames)
