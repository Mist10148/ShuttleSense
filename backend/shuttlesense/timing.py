"""Frame-count thresholds on clips that are not 30 fps.

The thresholds in configs/pipeline.yaml that count frames (the gap between hits, how long
the shuttle rests or is lost before a rally ends) are written for 30 fps video. A 25 fps
upload or a 10 fps webcam session covers more time per frame, so the same count would wait
far longer; `frames_at` turns a configured count into the count that covers the same time.
"""

from __future__ import annotations

from collections.abc import Iterable
from typing import Any

REFERENCE_FPS = 30.0


def frames_at(frames: float, fps: float | None) -> int:
    """`frames` at 30 fps as a whole number of frames at `fps` (at least 1)."""
    if not fps or fps <= 0:
        return max(1, int(round(frames)))
    return max(1, int(round(frames * fps / REFERENCE_FPS)))


def scaled(cfg: dict[str, Any], keys: Iterable[str], fps: float | None) -> dict[str, Any]:
    """A copy of `cfg` with the frame counts under `keys` (where set) converted to `fps`."""
    out = dict(cfg)
    for key in keys:
        if out.get(key) is not None:
            out[key] = frames_at(out[key], fps)
    return out
