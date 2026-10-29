from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


@pytest.fixture()
def ec():
    spec = importlib.util.spec_from_file_location("extract_clips", SCRIPTS / "extract_clips.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["extract_clips"] = module  # dataclasses look their module up
    spec.loader.exec_module(module)
    return module


def test_window_bounds(ec) -> None:
    strokes = [ec.Stroke(1, 1, 1, 100, "A", "short service"), ec.Stroke(1, 1, 2, 130, "B", "clear")]
    windows, skipped = ec.stroke_windows(strokes, pad=16, num_frames=1000)
    assert skipped == 0
    assert [(w.start, w.end, w.hit_frame_in_clip) for w in windows] == [
        (84, 116, 16),
        (114, 146, 16),
    ]
    _, skipped = ec.stroke_windows(strokes, pad=16, num_frames=140)  # 130 + 16 runs past the end
    assert skipped == 1


def test_skips_window_crossing_rally_end(ec) -> None:
    strokes = [
        ec.Stroke(1, 1, 1, 100, "A", "short service"),
        ec.Stroke(1, 1, 2, 140, "B", "smash"),
        ec.Stroke(1, 2, 1, 150, "B", "short service"),  # next rally starts 10 frames later
        ec.Stroke(1, 2, 2, 200, "A", "lob"),
    ]
    windows, skipped = ec.stroke_windows(strokes, pad=16, num_frames=1000)
    assert skipped == 2  # the smash window reaches into rally 2, the serve back into rally 1
    assert [(w.stroke.rally, w.stroke.stroke_no) for w in windows] == [(1, 1), (2, 2)]
