"""A high shuttle above the frame stays in play (D62)."""

from __future__ import annotations

import numpy as np

from shuttlesense.referee.rally import segment_rallies

CFG = {"lost_frames_end": 30, "stationary_frames_end": 20, "top_exit_frames": 75}


def _clear_above_the_frame(gap: int, back_at_y: float = 8.0) -> tuple[np.ndarray, np.ndarray]:
    """Hit at 10, out of view from 20 for `gap` frames, then coming down from `back_at_y`."""
    n = 200
    xy = np.array([[300.0 + 3 * i, 300.0 - 10 * (i % 30)] for i in range(n)], dtype=float)
    visible = np.ones(n, dtype=int)
    visible[:10] = 0  # nothing in play before the serve
    visible[20 : 20 + gap] = 0
    back = 20 + gap
    for k, i in enumerate(range(back, n)):
        xy[i] = [400.0, back_at_y + 12 * k]  # falling into the frame from the top edge
    return visible, xy


def test_a_shuttle_back_from_above_the_frame_is_the_same_rally() -> None:
    """Out of view for 42 frames (longer than lost_frames_end) after a high clear: one rally."""
    visible, xy = _clear_above_the_frame(42)
    segs = segment_rallies(visible, xy, [10, 90], CFG)
    assert len(segs) == 1
    assert segs[0].start == 10 and not segs[0].closed


def test_a_shuttle_that_never_comes_back_still_ends_the_rally() -> None:
    visible, xy = _clear_above_the_frame(42)
    visible[62:] = 0  # never seen again
    segs = segment_rallies(visible, xy, [10], CFG)
    assert len(segs) == 1 and segs[0].closed and segs[0].end == 19


def test_a_shuttle_back_too_late_or_not_at_the_top_is_a_new_rally() -> None:
    late, xy = _clear_above_the_frame(90)  # longer than top_exit_frames
    assert len(segment_rallies(late, xy, [10, 130], CFG)) == 2
    low, xy = _clear_above_the_frame(42, back_at_y=300.0)  # found mid-frame: something else
    assert len(segment_rallies(low, xy, [10, 90], CFG)) == 2


def test_an_unobserved_frame_in_the_gap_proves_nothing() -> None:
    visible, xy = _clear_above_the_frame(42)
    segs = segment_rallies(visible, xy, [10, 90], CFG, unobserved={55})
    assert len(segs) == 2
