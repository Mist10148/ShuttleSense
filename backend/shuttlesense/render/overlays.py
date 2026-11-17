"""Draw enabled overlays and export an MP4 (F7, FR-7).

Each overlay is a Layer: a function drawing in place on one BGR frame. Layers are
registered in LAYERS under the names in OVERLAYS, so later tasks add a layer without
touching the others.
"""

from __future__ import annotations

import logging
import time
from bisect import bisect_left, bisect_right
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.render import style
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext

log = logging.getLogger("uvicorn.error")

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
        pad = radius + 2  # Include anti-aliased edge pixels.
        x0, y0 = max(0, p[0] - pad), max(0, p[1] - pad)
        x1, y1 = min(img.shape[1], p[0] + pad + 1), min(img.shape[0], p[1] + pad + 1)
        if x0 >= x1 or y0 >= y1:
            continue
        region = img[y0:y1, x0:x1]
        overlay = region.copy()
        cv2.circle(overlay, (p[0] - x0, p[1] - y0), radius, style.SHUTTLE, -1, cv2.LINE_AA)
        cv2.addWeighted(overlay, alpha, region, 1 - alpha, 0, dst=region)


def court_type_of(record: ClipRecord) -> str:
    """ "doubles" for a record with partners or doubles line calls, else "singles"."""
    from shuttlesense.schema import is_doubles

    if is_doubles(record) or any(c.court == "doubles" for c in record.line_calls):
        return "doubles"
    return "singles"


def _player_labels(record: ClipRecord) -> tuple[tuple[str, str], ...]:
    """(Players field, label) for every player drawn: Near / Far, or the four slots."""
    from shuttlesense.schema import is_doubles

    if not is_doubles(record):
        return (("near", "Near"), ("far", "Far"))
    return (("near", "Near 1"), ("near_2", "Near 2"), ("far", "Far 1"), ("far_2", "Far 2"))


def draw_boxes(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    import cv2

    from shuttlesense.render.player_boxes import display_players

    thick = max(1, int(round(2 * state.scale)))
    if "labels" not in state.cache:
        state.cache["labels"] = _player_labels(record)
    boxes = display_players(record, i, float(state.stage("render").get("player_box_hold_s", 0.6)))
    for side, label in state.cache["labels"]:
        player = boxes.get(side)
        if player is None:
            continue
        x, y, w, h = player["bbox"]
        color = style.PLAYER_COLORS[side]
        if player["held"]:
            x0, y0 = max(0, round(x) - thick - 2), max(0, round(y) - thick - 2)
            x1 = min(img.shape[1], round(x + w) + thick + 3)
            y1 = min(img.shape[0], round(y + h) + thick + 3)
            if x0 < x1 and y0 < y1:
                region = img[y0:y1, x0:x1]
                overlay = region.copy()
                cv2.rectangle(overlay, _pt(x - x0, y - y0), _pt(x + w - x0, y + h - y0),
                              color, thick, cv2.LINE_AA)  # fmt: skip
                cv2.addWeighted(overlay, 0.4, region, 0.6, 0, dst=region)
            label += " (held)"
        else:
            cv2.rectangle(img, _pt(x, y), _pt(x + w, y + h), color, thick, cv2.LINE_AA)
        cv2.putText(img, label, _pt(x, y - 6 * state.scale), style.FONT, 0.6 * state.scale,
                    color, thick, cv2.LINE_AA)  # fmt: skip


def draw_pose(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    import cv2

    thick = max(1, int(round(2 * state.scale)))
    for side in ("near", "far", "near_2", "far_2"):
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


def _cached_last_hit(record: ClipRecord, i: int, state: RenderState):
    if state.cache.get("hits_record") is not record:
        state.cache["hits_record"] = record
        state.cache["hit_frames"] = [h.frame for h in record.hits]
    index = bisect_right(state.cache["hit_frames"], i) - 1
    return record.hits[index] if index >= 0 else None


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

    hit = _cached_last_hit(record, i, state)
    duration = state.stage("hits").get("marker_duration_s", 0.5) * (record.fps or 30)
    if hit is None or i - hit.frame > duration:
        return
    anchor = _hitter_anchor(record, hit.frame, hit.player_attr)
    if anchor is None:
        return
    t = (i - hit.frame) / max(duration, 1)
    radius = int((12 + 30 * t) * state.scale)
    color = style.PLAYER_COLORS[hit.player_attr]
    cv2.circle(img, _pt(*anchor), radius, style.HIT, max(1, int(3 * (1 - t) * state.scale) + 1),
               cv2.LINE_AA)  # fmt: skip
    _label(img, "HIT", _pt(anchor[0] + 14 * state.scale, anchor[1] - 14 * state.scale), color,
           state.scale)  # fmt: skip


def draw_strokes(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    """Stroke and confidence ("Smash 81%") above the hitter's box until the next hit."""
    hit = _cached_last_hit(record, i, state)
    if hit is None or hit.stroke is None:
        return
    p = getattr(record.frames[i].players, hit.player_attr)
    if p is None:
        return
    x, y, _w, _h = p.bbox
    text = hit.stroke.replace("_", " ").capitalize()
    if hit.confidence is not None:
        text += f" {hit.confidence:.0%}"
    _label(img, text, _pt(x, y - 24 * state.scale), style.PLAYER_COLORS[hit.player_attr],
           state.scale)  # fmt: skip


def court_segments_px(record: ClipRecord, state: RenderState) -> list[tuple]:
    """All court line segments in image pixels (computed once per video)."""
    if "court_px" not in state.cache:
        from shuttlesense.court import court_lines, court_to_image

        segments = []
        if record.court is not None:
            h = np.asarray(record.court.homography)
            court = court_type_of(record)
            for group in court_lines(record.court.court_size_m, court).values():
                for a, b in group:
                    pa, pb = court_to_image(h, np.array([a, b]))
                    segments.append((_pt(*pa), _pt(*pb)))
        state.cache["court_px"] = segments
    return state.cache["court_px"]


def draw_court(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    """Semi-transparent court lines (singles, or doubles with its alleys) from court meters."""
    import cv2

    segments = court_segments_px(record, state)
    if not segments:
        return
    thick = max(1, int(round(3 * state.scale)))
    # Only the bounding rectangle of the fixed court can change. Keep a margin for
    # antialiasing and clip it to the image; drawing order and blending are unchanged.
    key = (img.shape[:2], thick)
    if state.cache.get("court_region_key") != key:
        pad = thick + 3
        xs = [p[0] for line in segments for p in line]
        ys = [p[1] for line in segments for p in line]
        state.cache["court_region_key"] = key
        state.cache["court_region"] = (
            max(0, min(xs) - pad),
            max(0, min(ys) - pad),
            min(img.shape[1], max(xs) + pad + 1),
            min(img.shape[0], max(ys) + pad + 1),
        )
    x0, y0, x1, y1 = state.cache["court_region"]
    if x0 >= x1 or y0 >= y1:
        return
    region = img[y0:y1, x0:x1]
    overlay = region.copy()
    for a, b in segments:
        cv2.line(
            overlay, (a[0] - x0, a[1] - y0), (b[0] - x0, b[1] - y0), style.COURT, thick, cv2.LINE_AA
        )
    cv2.addWeighted(overlay, 0.6, region, 0.4, 0, dst=region)


def status_text(
    record: ClipRecord,
    i: int,
    *,
    peak_history: list | None = None,
    stroke_counts: list[int] | None = None,
) -> str:
    """'In play · 182 km/h (est.) · peak 241 · 3 strokes' for frame i."""
    from shuttlesense.analytics.stage import strokes_so_far

    parts = []
    frame = record.frames[i]
    if frame.rally_state:
        parts.append("In play" if frame.rally_state == "in_play" else "Between rallies")
    if frame.shuttle_speed_kmh is not None:
        parts.append(f"{frame.shuttle_speed_kmh:.0f} km/h (est.)")
    if peak_history is None:
        peaks = [f.shuttle_speed_kmh for f in record.frames[: i + 1] if f.shuttle_speed_kmh]
        peak = max(peaks) if peaks else None
    else:
        peak = peak_history[i]
    if peak is not None:
        parts.append(f"peak {peak:.0f}")
    count = strokes_so_far(record, i) if stroke_counts is None else stroke_counts[i]
    parts.append(f"{count} stroke{'s' if count != 1 else ''}")
    return " | ".join(parts)


def draw_speed(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    """Status bar at the bottom left: rally state, estimated speed, peak, stroke count."""
    if state.cache.get("peak_record") is not record:
        peak = None
        history = []
        for frame in record.frames:
            speed = frame.shuttle_speed_kmh
            if speed and (peak is None or speed > peak):
                peak = speed
            history.append(peak)
        state.cache["peak_record"], state.cache["peak_history"] = record, history
        hit_frames = sorted(h.frame for h in record.hits)
        rally_events = sorted((r.start_frame, n) for n, r in enumerate(record.rallies))
        next_rally, last_rally, counts = 0, -1, []
        for frame in range(len(record.frames)):
            while next_rally < len(rally_events) and rally_events[next_rally][0] <= frame:
                last_rally = max(last_rally, rally_events[next_rally][1])
                next_rally += 1
            start = record.rallies[last_rally].start_frame if last_rally >= 0 else 0
            counts.append(bisect_right(hit_frames, frame) - bisect_left(hit_frames, start))
        state.cache["stroke_counts"] = counts
    _label(img, status_text(record, i, peak_history=state.cache["peak_history"],
                            stroke_counts=state.cache["stroke_counts"]),
           _pt(12 * state.scale, img.shape[0] - 14 * state.scale),
           style.PANEL, state.scale)  # fmt: skip


def minimap_rect(img_shape: tuple[int, ...], size: tuple[float, float], corner: str,
                 height_frac: float = 0.2) -> tuple[int, int, int, int]:  # fmt: skip
    """(x, y, w, h) of the minimap: `height_frac` of the frame tall, court aspect ratio."""
    fh, fw = img_shape[:2]
    margin = max(4, int(fh * 0.02))
    h = max(20, int(fh * height_frac))
    w = max(10, int(h * size[0] / size[1]))
    x = margin if "left" in corner else fw - w - margin
    y = margin if "top" in corner else fh - h - margin
    return x, y, w, h


def draw_minimap(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    """Top-down court in a corner with both players and the shuttle (same geometry as the app)."""
    import cv2

    from shuttlesense.court import court_lines

    pos = record.frames[i].court_positions
    if record.court is None or pos is None:
        return
    from shuttlesense.court.lines import DOUBLES_SIDE_ALLEY_M

    if state.cache.get("minimap_record") is not record:
        state.cache["minimap_record"] = record
        state.cache["minimap_court"] = court_type_of(record)
    court = state.cache["minimap_court"]
    lines_size = record.court.court_size_m
    alley = DOUBLES_SIDE_ALLEY_M if court == "doubles" else 0.0
    size = (lines_size[0] + 2 * alley, lines_size[1])  # the panel shows the doubles alleys
    corner = state.stage("render").get("minimap_corner", "top-right")
    x, y, w, h = minimap_rect(img.shape, size, corner)

    def to_px(p: tuple[float, float]) -> tuple[int, int]:
        # Court y grows toward the far baseline: draw the near side at the bottom, like the app.
        # Points off the court (players behind the baseline) are pinned to the panel edge.
        px = min(max(int(x + (p[0] + alley) / size[0] * w), x + radius + 1), x + w - radius - 2)
        py = min(max(int(y + h - p[1] / size[1] * h), y + radius + 1), y + h - radius - 2)
        return px, py

    radius = max(2, int(h / 40))
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(img.shape[1], x + w), min(img.shape[0], y + h)
    if x0 < x1 and y0 < y1:
        region = img[y0:y1, x0:x1]
        panel = np.full_like(region, style.MINIMAP_BG)
        cv2.addWeighted(panel, 0.75, region, 0.25, 0, dst=region)
    for group in court_lines(lines_size, court).values():
        for a, b in group:
            cv2.line(img, to_px(a), to_px(b), style.COURT, 1, cv2.LINE_AA)
    dots = (("near", style.NEAR), ("far", style.FAR), ("near_2", style.NEAR_2),
            ("far_2", style.FAR_2), ("shuttle", style.SHUTTLE))  # fmt: skip
    for key, color in dots:
        p = getattr(pos, key)
        if p is not None:
            r = radius if key != "shuttle" else max(2, radius - 1)
            cv2.circle(img, to_px(p), r, color, -1, cv2.LINE_AA)


def score_at(record: ClipRecord, i: int) -> tuple[int, int] | None:
    """Score at frame i: after the last rally that ended by then, plus the points awarded
    since (an award counts from its frame on). None without a referee. Same as the app's
    ClipRecord.scoreAt."""
    if record.score is None:
        return None
    awards = [c for c in record.score.corrections if c.kind == "award" and c.winner_after]

    def shift(score: tuple[int, int], winner: str | None, by: int) -> tuple[int, int]:
        near, far = score
        return (max(0, near + (by if winner == "near" else 0)),
                max(0, far + (by if winner == "far" else 0)))  # fmt: skip

    # Awards placed before rally k count in its score_after; the start score has none.
    current = (record.score.near, record.score.far)  # no counted rally: start + every award
    first = next((r for r in record.rallies if r.score_after is not None), None)
    if first is not None:
        current = shift((first.score_after.near, first.score_after.far), first.winner, -1)
    for a in awards:
        if first is None or a.rally_index <= first.index:
            current = shift(current, a.winner_after, -1)
    last = None
    # v1.7: near / far are the ends at that moment. `shown` is how the ends stood when
    # `current` was true, `now` how they stand at frame i; the pair is turned when they differ.
    shown = first.ends_swapped if first is not None else False
    now = shown
    for r in record.rallies:
        if r.end_frame <= i and r.score_after is not None:
            current, last = (r.score_after.near, r.score_after.far), r.index
            shown, now = r.ends_swapped, r.ends_swapped != r.change_ends
    for a in awards:
        if (last is None or a.rally_index > last) and (a.frame or 0) <= i:
            current = shift(current, a.winner_after, 1)
    for c in record.score.corrections:  # changes of ends made by hand since then
        if c.kind == "ends" and (c.frame or 0) <= i and (
            c.rally_index > last if last is not None
            else first is None or c.rally_index <= first.index
        ):  # fmt: skip
            now = not now
    return current if now == shown else (current[1], current[0])


def draw_score(img: np.ndarray, record: ClipRecord, i: int, state: RenderState) -> None:
    """Scoreboard (Near : Far) at the top left and a landing marker for 1 s after landing."""
    import cv2

    if state.cache.get("score_record") is not record:
        state.cache["score_record"] = record
        changes = {0}
        changes.update(r.end_frame for r in record.rallies if r.end_frame >= 0)
        if record.score is not None:
            changes.update((c.frame or 0) for c in record.score.corrections if (c.frame or 0) >= 0)
        events = sorted(changes)
        state.cache["score_events"] = events
        state.cache["score_values"] = [score_at(record, frame) for frame in events]
    events = state.cache["score_events"]
    score = (
        state.cache["score_values"][bisect_right(events, i) - 1] if i >= 0 else score_at(record, i)
    )
    if score is None:
        return
    s = state.scale
    _label(img, f"Near {score[0]}", _pt(12 * s, 28 * s), style.NEAR, s)
    _label(img, f"Far {score[1]}", _pt(12 * s, 58 * s), style.FAR, s)

    fps = record.fps or 30.0
    for r in record.rallies:
        if r.landing is None or record.court is None or not 0 <= i - r.end_frame <= fps:
            continue
        from shuttlesense.court import court_to_image

        h = np.asarray(record.court.homography)
        p = court_to_image(h, np.array([[r.landing.x_m, r.landing.y_m]]))[0]
        if r.landing.confidence < 0.5:
            color = style.UNCERTAIN_CALL
        else:
            color = style.IN_COURT if r.landing.in_court else style.OUT_COURT
        cv2.circle(img, _pt(*p), int(10 * s), color, max(2, int(3 * s)), cv2.LINE_AA)


LAYERS: dict[str, Layer] = {
    "score": draw_score,
    "minimap": draw_minimap,
    "speed": draw_speed,
    "court": draw_court,
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
    started = time.perf_counter()
    draw_s = write_s = 0.0
    with VideoWriter(
        out_path,
        fps=record.fps or 30.0,
        size=(record.width, record.height),
        crf=render_cfg.get("crf", 23),
        codec=render_cfg.get("codec", "libx264"),
    ) as writer:
        for i, img in frames:
            step = time.perf_counter()
            drawn = draw_frame(img, record, i, overlays, state)
            draw_s += time.perf_counter() - step
            step = time.perf_counter()
            writer.write(drawn)
            write_s += time.perf_counter() - step
            if i % 25 == 0:
                progress(i / total)
    elapsed = time.perf_counter() - started
    log.info(
        "Render: %d frames in %.2fs; overlays %.2fs, writer/pipe %.2fs, "
        "other (frame read, setup, finalization) %.2fs; encoder=%s",
        writer.frames,
        elapsed,
        draw_s,
        write_s,
        max(0.0, elapsed - draw_s - write_s),
        writer.codec if writer.backend == "ffmpeg" else writer.backend,
    )
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
