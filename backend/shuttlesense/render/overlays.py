"""Draw enabled overlays and export an MP4 (F7, FR-7).

Each overlay is a Layer: a function drawing in place on one BGR frame. Layers are
registered in LAYERS under the names in OVERLAYS, so later tasks add a layer without
touching the others.
"""

from __future__ import annotations

import logging
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.render import style
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext

log = logging.getLogger(__name__)

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


@dataclass
class RenderState:
    """Per-video data shared by layers (config blocks, precomputed lookups)."""

    config: dict[str, Any] = field(default_factory=dict)
    scale: float = 1.0
    cache: dict[str, Any] = field(default_factory=dict)

    def stage(self, name: str) -> dict[str, Any]:
        return self.config.get("stages", {}).get(name, {})


Layer = Callable[[np.ndarray, ClipRecord, int, RenderState], None]


def _pt(x: float, y: float) -> tuple[int, int]:
    return int(round(x)), int(round(y))


def draw_trail(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    """Last trail_length visible shuttle positions, older ones smaller and fainter."""
    import cv2

    length = state.stage("tracking").get("trail_length", 12)
    points = []
    for f in record.frames[max(0, i - length + 1) : i + 1]:
        s = f.shuttle
        if s is not None and s.visible and s.x is not None and s.y is not None:
            points.append((f.frame, _pt(s.x, s.y)))
    for frame_idx, p in points:
        age = (i - frame_idx) / max(length, 1)  # 0 = newest
        alpha = 1.0 - 0.8 * age
        radius = max(1, int(round((6 - 4 * age) * state.scale)))
        overlay = img.copy()
        cv2.circle(overlay, p, radius, style.SHUTTLE, -1, cv2.LINE_AA)
        cv2.addWeighted(overlay, alpha, img, 1 - alpha, 0, dst=img)


def draw_boxes(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    import cv2

    thick = max(1, int(round(2 * state.scale)))
    for side, label in (("near", "Near"), ("far", "Far")):
        p = getattr(record.frames[i].players, side)
        if p is None:
            continue
        x, y, w, h = p.bbox
        color = style.PLAYER_COLORS[side]
        cv2.rectangle(img, _pt(x, y), _pt(x + w, y + h), color, thick, cv2.LINE_AA)
        cv2.putText(img, label, _pt(x, y - 6 * state.scale), style.FONT, 0.6 * state.scale,
                    color, thick, cv2.LINE_AA)  # fmt: skip


def draw_pose(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    import cv2

    thick = max(1, int(round(2 * state.scale)))
    for side in ("near", "far"):
        p = getattr(record.frames[i].players, side)
        if p is None or len(p.keypoints) < 17:
            continue
        color = style.PLAYER_COLORS[side]
        kps = p.keypoints
        for a, b in style.SKELETON_EDGES:
            if kps[a][2] >= style.MIN_KEYPOINT_SCORE and kps[b][2] >= style.MIN_KEYPOINT_SCORE:
                cv2.line(img, _pt(*kps[a][:2]), _pt(*kps[b][:2]), color, thick, cv2.LINE_AA)
        for x, y, s in kps:
            if s >= style.MIN_KEYPOINT_SCORE:
                cv2.circle(img, _pt(x, y), thick + 1, style.TEXT, -1, cv2.LINE_AA)


def _last_hit_before(record: ClipRecord, i: int):
    """The most recent hit at or before frame i (hits are in frame order)."""
    last = None
    for h in record.hits:
        if h.frame > i:
            break
        last = h
    return last


def _hitter_anchor(record: ClipRecord, frame: int, side: str) -> tuple[float, float] | None:
    """Hitter's best wrist at `frame`, else the top of their box."""
    p = getattr(record.frames[frame].players, side) if frame < len(record.frames) else None
    if p is None:
        return None
    wrists = [p.keypoints[k] for k in (9, 10) if len(p.keypoints) > k]
    wrists = [w for w in wrists if w[2] >= style.MIN_KEYPOINT_SCORE]
    if wrists:
        best = max(wrists, key=lambda w: w[2])
        return best[0], best[1]
    x, y, w, _h = p.bbox
    return x + w / 2, y


def _label(img: np.ndarray, text: str, org: tuple[int, int], color, scale: float) -> None:
    """Text on a filled background so it reads on any court colour."""
    import cv2

    font_scale = 0.6 * scale
    thick = max(1, int(round(1.5 * scale)))
    (tw, th), base = cv2.getTextSize(text, style.FONT, font_scale, thick)
    x, y = max(0, org[0]), max(th + base, org[1])
    pad = int(4 * scale)
    cv2.rectangle(img, (x - pad, y - th - pad), (x + tw + pad, y + base), color, -1)
    cv2.putText(img, text, (x, y), style.FONT, font_scale, style.TEXT, thick, cv2.LINE_AA)


def draw_hits(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    """ "HIT" badge and an expanding ring at the hitter's wrist for marker_duration_s."""
    import cv2

    hit = _last_hit_before(record, i)
    duration = state.stage("hits").get("marker_duration_s", 0.5) * (record.fps or 30)
    if hit is None or i - hit.frame > duration:
        return
    anchor = _hitter_anchor(record, hit.frame, hit.player)
    if anchor is None:
        return
    t = (i - hit.frame) / max(duration, 1)
    radius = int((12 + 30 * t) * state.scale)
    color = style.PLAYER_COLORS[hit.player]
    cv2.circle(img, _pt(*anchor), radius, style.HIT, max(1, int(3 * (1 - t) * state.scale) + 1),
               cv2.LINE_AA)  # fmt: skip
    _label(img, "HIT", _pt(anchor[0] + 14 * state.scale, anchor[1] - 14 * state.scale), color,
           state.scale)  # fmt: skip


def draw_strokes(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    """Stroke and confidence ("Smash 81%") above the hitter's box until the next hit."""
    hit = _last_hit_before(record, i)
    if hit is None or hit.stroke is None:
        return
    p = getattr(record.frames[i].players, hit.player)
    if p is None:
        return
    x, y, _w, _h = p.bbox
    text = hit.stroke.replace("_", " ").capitalize()
    if hit.confidence is not None:
        text += f" {hit.confidence:.0%}"
    _label(img, text, _pt(x, y - 24 * state.scale), style.PLAYER_COLORS[hit.player], state.scale)


LAYERS: dict[str, Layer] = {
    "trail": draw_trail,
    "pose": draw_pose,
    "boxes": draw_boxes,
    "hits": draw_hits,
    "strokes": draw_strokes,
}


def draw_frame(
    img: np.ndarray, record: ClipRecord, i: int, overlays: Sequence[str], state: RenderState
) -> np.ndarray:
    """Apply the selected layers, in the order given, to one frame (in place)."""
    for name in overlays:
        layer = LAYERS.get(name)
        if layer is not None and i < len(record.frames):
            layer(img, record, i, state)
    return img


def render_video(
    record: ClipRecord,
    frames,
    out_path: Path,
    *,
    overlays: Sequence[str],
    config: dict[str, Any] | None = None,
    progress: Callable[[float], None] = lambda _p: None,
) -> Path:
    """Draw overlays on every (index, frame) from `frames` and write `out_path`."""
    from shuttlesense.render.writer import VideoWriter

    missing = [n for n in overlays if n not in LAYERS]
    if missing:
        log.info("overlays not implemented yet, skipped: %s", ", ".join(missing))
    config = config or {}
    state = RenderState(config=config, scale=style.scale_for(record.height))
    render_cfg = config.get("stages", {}).get("render", {})
    total = max(record.num_frames, 1)
    with VideoWriter(
        out_path,
        fps=record.fps or 30.0,
        size=(record.width, record.height),
        crf=render_cfg.get("crf", 23),
        codec=render_cfg.get("codec", "libx264"),
    ) as writer:
        for i, img in frames:
            writer.write(draw_frame(img, record, i, overlays, state))
            if i % 25 == 0:
                progress(i / total)
    progress(1.0)
    return out_path


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Write ctx.out_dir / "annotated.mp4" with the overlays in ctx.overlays."""
    if ctx.reader is None:
        from shuttlesense.io import FrameReader

        io_cfg = ctx.stage_config("io")
        ctx.reader = FrameReader(
            ctx.video_path, io_cfg.get("target_height", 720), io_cfg.get("max_fps", 30)
        )
    render_video(
        record,
        ctx.reader,
        ctx.out_dir / "annotated.mp4",
        overlays=ctx.overlays,
        config=ctx.config,
        progress=ctx.progress,
    )
    return record
