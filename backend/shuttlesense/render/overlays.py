"""Draw enabled overlays and export an H.264 MP4 (F7, FR-7)."""

from __future__ import annotations

from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext

# Overlay names accepted by the API and CLI (docs/API.md).
OVERLAYS: tuple[str, ...] = (
    "trail",
    "pose",
    "boxes",
    "hits",
    "strokes",
    "court",
    "minimap",
    "speed",
    "score",
)


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Write ctx.out_dir / "annotated.mp4" with the overlays in ctx.overlays.

    TODO(T2.6): one draw function per overlay, applied frame by frame.
    TODO(T2.7): encode with ffmpeg (libx264, yuv420p, +faststart); fall back to OpenCV mp4v.
    TODO(T3.11, T5.3, T6.6): hit marker, stroke label, court outline, scoreboard layers.
    """
    ctx.progress(1.0)
    return record
