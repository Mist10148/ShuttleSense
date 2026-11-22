"""Model-independent shuttle post-processing (F2): heatmaps to points, outliers, gaps, CSV.

Everything here is pure NumPy/OpenCV so it is tested without TrackNetV3 or a GPU.
"""

from __future__ import annotations

import contextlib
import contextvars
import csv
import functools
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.schema import ClipRecord, Shuttle
from shuttlesense.tracking.interpolate import interpolate_gaps

TRACKING_CSV_COLUMNS = ("frame", "visible", "x", "y", "source")

# Tracking precision settings (D43). rectify() is called with only max_gap and outlier_px,
# so the rest is read here from stages.tracking.precision in configs/pipeline.yaml, over
# these defaults. Pixel values are for 720p.
PRECISION_DEFAULTS: dict[str, Any] = {
    "depth_aware": True,  # outlier and burst distances follow the image row
    "depth_far_scale": 0.7,  # threshold multiplier at the top row (far court, small)
    "depth_near_scale": 1.2,  # ... and at the bottom row (near court, large)
    "trajectory": True,  # flight segments, long-gap fill and smoothing (trajectory.py)
    "trajectory_live": False,  # also on live / Watch windows (about 150 ms per tick)
    "split_angle_deg": 40.0,  # a turn sharper than this ends a flight segment
    "min_split_speed_px": 2.0,  # per frame, on both sides, for a turn to count
    "reject_px": 12.0,  # a point this far from both sides' agreeing prediction is dropped
    "fill_max_gap": 20,  # frames: gaps up to this are filled from a fitted flight
    "fill_max_rms_px": 4.0,  # ... when one quadratic flight fits both ends this well
    "fill_context": 8,  # frames on each side of a gap used for that fit
    "smooth_half_window": 3,  # frames each side of the local quadratic smoother
    "min_segment_points": 6,  # shorter segments are left as detected
}
OUTLIER_PX_720 = 80.0  # stages.tracking.outlier_px default, used to infer the frame height


@functools.lru_cache(maxsize=1)
def _configured_precision() -> dict[str, Any]:
    from shuttlesense.config import load_config

    try:
        stages = load_config().get("stages") or {}
    except Exception:  # an unreadable config must not stop tracking
        return {}
    return dict((stages.get("tracking") or {}).get("precision") or {})


_OFFLINE: contextvars.ContextVar[bool] = contextvars.ContextVar("offline_tracking", default=False)


_IMAGE_HEIGHT: contextvars.ContextVar[int | None] = contextvars.ContextVar(
    "image_height", default=None
)


@contextlib.contextmanager
def offline_tracking(height: int | None = None) -> Iterator[None]:
    """Mark rectify calls inside as a whole uploaded clip (the tracking stage), where the
    flight fitting runs. Live and Watch windows call rectify every tick and leave it off
    unless stages.tracking.precision.trajectory_live is set."""
    token = _OFFLINE.set(True)
    height_token = _IMAGE_HEIGHT.set(height)
    try:
        yield
    finally:
        _OFFLINE.reset(token)
        _IMAGE_HEIGHT.reset(height_token)


def precision_settings(overrides: dict[str, Any] | None = None) -> dict[str, Any]:
    """PRECISION_DEFAULTS, then stages.tracking.precision from pipeline.yaml, then overrides."""
    return {**PRECISION_DEFAULTS, **_configured_precision(), **(overrides or {})}


@dataclass(frozen=True)
class HeatmapPeak:
    """The chosen blob of a heatmap: position in heatmap pixels, peak value and size."""

    x: float
    y: float
    visible: int
    confidence: float  # the blob's peak heatmap value; 0 when nothing passed the threshold
    area: int


MAX_BLOBS = 8  # candidates scored per heatmap, largest first


def _peak_offset(left: float, centre: float, right: float) -> float | None:
    """Sub-pixel offset of a strict 3-sample maximum: a Gaussian (log-parabola) fit when the
    values are positive, else a parabola. None when the top is flat or not a strict peak."""
    if not (centre > left and centre > right):
        return None
    if left > 0 and right > 0:
        a, b, c = float(np.log(left)), float(np.log(centre)), float(np.log(right))
    else:
        a, b, c = float(left), float(centre), float(right)
    denom = a - 2 * b + c
    if denom >= -1e-9:
        return None
    offset = 0.5 * (a - c) / denom
    return offset if abs(offset) <= 0.5 else None


def heatmap_peak(
    heatmap: np.ndarray,
    threshold: float = 0.5,
    *,
    predicted: tuple[float, float] | None = None,
    predicted_scale_px: float = 20.0,
) -> HeatmapPeak:
    """The shuttle blob of a (H, W) heatmap, located to a fraction of a pixel.

    Blobs are the connected components above `threshold`. Each is scored by peak value x
    area, so a solid blob beats both a faint smear and a bright speck; with a `predicted`
    position (heatmap pixels, e.g. extrapolated from the track) the score is divided by
    1 + (distance / predicted_scale_px)^2. The chosen blob is placed at its peak, refined
    by a 3-point Gaussian fit along each axis, when the peak is a strict maximum; on a flat
    top (a saturated heatmap) the centroid weighted by the height above the threshold
    stands in, so the cut-off edge pixels count least.
    """
    import cv2

    heatmap = np.asarray(heatmap, dtype=np.float64)
    mask = (heatmap >= threshold).astype(np.uint8)
    count, labels, stats, centroids = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if count <= 1:  # label 0 is the background
        return HeatmapPeak(0.0, 0.0, 0, 0.0, 0)
    areas = stats[1:, cv2.CC_STAT_AREA]
    order = 1 + np.argsort(-areas, kind="stable")[:MAX_BLOBS]
    best: tuple[float, int, np.ndarray, int, int] | None = None
    for label in order:
        x0, y0, w, h = (int(v) for v in stats[label, :4])
        inside = labels[y0 : y0 + h, x0 : x0 + w] == label
        values = np.where(inside, heatmap[y0 : y0 + h, x0 : x0 + w], -np.inf)
        score = float(values.max()) * float(stats[label, cv2.CC_STAT_AREA])
        if predicted is not None:
            d = float(np.hypot(*(centroids[label] - np.asarray(predicted, dtype=float))))
            score /= 1.0 + (d / predicted_scale_px) ** 2
        if best is None or score > best[0]:
            best = (score, int(label), values, x0, y0)
    assert best is not None
    _, label, values, x0, y0 = best
    peak = float(values.max())
    area = int(stats[label, cv2.CC_STAT_AREA])
    py, px = np.unravel_index(int(np.argmax(values)), values.shape)
    gy, gx = y0 + int(py), x0 + int(px)
    rows, cols = heatmap.shape
    if 0 < gx < cols - 1 and 0 < gy < rows - 1:
        dx = _peak_offset(heatmap[gy, gx - 1], heatmap[gy, gx], heatmap[gy, gx + 1])
        dy = _peak_offset(heatmap[gy - 1, gx], heatmap[gy, gx], heatmap[gy + 1, gx])
        if dx is not None and dy is not None:
            return HeatmapPeak(gx + dx, gy + dy, 1, peak, area)
    inside = np.isfinite(values)
    weights = np.where(inside, values - threshold, 0.0)
    if float(np.ptp(weights[inside])) < 1e-9 or weights.sum() <= 0:
        x, y = centroids[label]  # a flat blob: its plain centroid
        return HeatmapPeak(float(x), float(y), 1, peak, area)
    ys, xs = np.indices(weights.shape)
    total = float(weights.sum())
    x = x0 + float((weights * xs).sum()) / total
    y = y0 + float((weights * ys).sum()) / total
    return HeatmapPeak(x, y, 1, peak, area)


def heatmap_to_xy(
    heatmap: np.ndarray,
    threshold: float = 0.5,
    *,
    predicted: tuple[float, float] | None = None,
) -> tuple[float, float, int]:
    """(x, y, visible) of the shuttle blob in a (H, W) heatmap, in heatmap pixels.

    Binarized at `threshold` as upstream TrackNetV3 does; the blob is then chosen and
    located by `heatmap_peak` (sub-pixel; its peak value is the confidence there).
    """
    p = heatmap_peak(heatmap, threshold, predicted=predicted)
    return (p.x, p.y, 1) if p.visible else (0.0, 0.0, 0)


def scale_to_video(
    xy: np.ndarray, from_size: tuple[int, int], to_size: tuple[int, int]
) -> np.ndarray:
    """Scale (N, 2) points from a (w, h) network input to (w, h) normalized video pixels."""
    sx = to_size[0] / from_size[0]
    sy = to_size[1] / from_size[1]
    return np.asarray(xy, dtype=float) * np.array([sx, sy])


# A burst is a short run of detections that no shuttle could have reached: more than this
# many times `outlier_px` per frame away from the track on both sides. 2.5 x 80 px is about
# 6 m a frame at 720p, far beyond the fastest smash.
BURST_SPEED = 2.5


def depth_scale(y: np.ndarray, height: float, far_scale: float, near_scale: float) -> np.ndarray:
    """Per-row threshold multiplier: `far_scale` at the top of the image (the far court,
    where the shuttle and its moves look smallest), rising linearly to `near_scale` at the
    bottom."""
    t = np.clip(np.asarray(y, dtype=float) / max(float(height), 1.0), 0.0, 1.0)
    return far_scale + (near_scale - far_scale) * t


def infer_frame_height(xy: np.ndarray, visible: np.ndarray, outlier_px: float) -> float:
    """Frame height for the row ramp when the caller does not give one.

    The offline stage passes outlier_px for 720p on 720p frames and live sessions scale it
    by height / 720, so the height follows from it; the lowest visible point is a floor.
    """
    height = 720.0 * float(outlier_px) / OUTLIER_PX_720
    vis = np.asarray(visible) > 0
    if vis.any():
        lowest = np.nanmax(np.asarray(xy, dtype=float)[vis, 1])
        if np.isfinite(lowest):
            height = max(height, float(lowest) + 1.0)
    return height


def _drop_bursts(
    xy: np.ndarray,
    visible: np.ndarray,
    jump_px: float,
    max_burst: int,
    *,
    row_scale: np.ndarray | None = None,
) -> None:
    """Hide runs of up to `max_burst` detections that sit off the track (in place).

    A run is cut wherever the shuttle would have had to move more than `jump_px` per frame.
    A short run between two such cuts is a false detection (a racket, a shoe, a light) when
    the track on either side of it joins up without it. `row_scale` (per frame, see
    `depth_scale`) scales `jump_px` by depth: a step uses the mean scale of its two ends.
    """
    idx = np.flatnonzero(visible)
    if len(idx) < 3:
        return
    scale = np.ones(len(xy)) if row_scale is None else np.asarray(row_scale, dtype=float)
    step = np.linalg.norm(np.diff(xy[idx], axis=0), axis=1) / np.diff(idx)
    limit = jump_px * (scale[idx[:-1]] + scale[idx[1:]]) / 2
    cuts = [0, *(np.flatnonzero(step > limit) + 1), len(idx)]
    for a, b in zip(cuts[1:-2], cuts[2:-1], strict=True):
        before, after = idx[a - 1], idx[b]
        reach = jump_px * (scale[before] + scale[after]) / 2 * (after - before)
        joins = np.linalg.norm(xy[after] - xy[before]) <= reach
        if b - a <= max_burst and joins:
            visible[idx[a:b]] = 0


def remove_outliers(
    xy: np.ndarray,
    visible: np.ndarray,
    outlier_px: float,
    window: int = 2,
    max_burst: int = 3,
    *,
    frame_height: float | None = None,
    depth_aware: bool | None = None,
) -> np.ndarray:
    """Hide false detections. Returns a new visible array.

    Two rules: short bursts that jump off the track and back (`_drop_bursts`), then isolated
    detections, with no visible neighbour within +-window frames, farther than `outlier_px`
    from the last kept point.

    Depth-aware (stages.tracking.precision.depth_aware, D43): both distances are scaled by
    the image row (`depth_scale`), tighter near the top of the frame where the far court
    is. `frame_height` defaults to one inferred from `outlier_px` (`infer_frame_height`).
    """
    settings = precision_settings()
    if depth_aware is None:
        depth_aware = bool(settings["depth_aware"])
    xy = np.asarray(xy, dtype=float)
    visible = visible.astype(int).copy()
    n = len(visible)
    row_scale = None
    if depth_aware and n:
        height = frame_height or _IMAGE_HEIGHT.get() or infer_frame_height(xy, visible, outlier_px)
        far, near = float(settings["depth_far_scale"]), float(settings["depth_near_scale"])
        row_scale = depth_scale(np.nan_to_num(xy[:, 1]), height, far, near)
    if max_burst > 0:
        _drop_bursts(xy, visible, BURST_SPEED * outlier_px, max_burst, row_scale=row_scale)
    last: np.ndarray | None = None
    last_i = 0
    for i in range(n):
        if not visible[i]:
            continue
        lo, hi = max(0, i - window), min(n, i + window + 1)
        isolated = visible[lo:hi].sum() == 1
        limit = outlier_px
        if row_scale is not None:
            limit *= (row_scale[i] + row_scale[last_i]) / 2
        if isolated and last is not None and np.hypot(*(xy[i] - last)) > limit:
            visible[i] = 0
            continue
        last, last_i = xy[i], i
    return visible


def rectify(
    xy: np.ndarray,
    visible: np.ndarray,
    *,
    max_gap: int,
    outlier_px: float,
    frame_height: float | None = None,
    settings: dict[str, Any] | None = None,
) -> tuple[np.ndarray, np.ndarray, list[str]]:
    """Outlier removal, flight fitting and gap filling. Returns (xy, visible, source per
    frame) where source is "net", "interp" or "" (invisible).

    With stages.tracking.precision.trajectory (on by default, D43) the track is split into
    flight segments at sharp turns, points both sides of a flight disagree with are
    dropped, each segment is smoothed on its own, and gaps up to `fill_max_gap` frames are
    filled from one quadratic flight fitted to both ends when it fits them well
    (tracking/trajectory.py). Gaps left after that, up to `max_gap`, are interpolated as
    before. `settings` overrides `precision_settings()` (tests and ablations).
    """
    cfg = precision_settings(settings)
    xy = np.asarray(xy, dtype=float)
    height = frame_height or _IMAGE_HEIGHT.get() or infer_frame_height(xy, visible, outlier_px)
    kept = remove_outliers(
        xy, visible, outlier_px, frame_height=height, depth_aware=bool(cfg["depth_aware"])
    )
    original_xy = xy
    fitted = np.zeros(len(kept), dtype=bool)
    fit_flights = cfg["trajectory"] and (_OFFLINE.get() or cfg.get("trajectory_live", False))
    if fit_flights and kept.sum() >= 3:
        from shuttlesense.tracking.trajectory import refine_track

        refined = refine_track(xy, kept, settings=cfg, frame_height=height)
        xy, kept, fitted = refined.xy, refined.kept, refined.filled
    filled_xy, filled = interpolate_gaps(xy, ((kept > 0) | fitted).astype(int), max_gap)
    if _OFFLINE.get():
        # InpaintNet deliberately skips gaps at the top border. The fallback curve
        # must also respect an upward exit and downward re-entry at that border.
        measured = np.flatnonzero(visible)
        edges = np.flatnonzero(np.diff(measured) > 1)
        for edge in edges:
            left, right = measured[edge : edge + 2]
            # The first reappearing blob may cover only a few pixels. Look one
            # frame farther when available so a subpixel wobble cannot hide the descent.
            before, after = left, right
            for _ in range(2):
                if before > 0 and visible[before - 1]:
                    before -= 1
                if after + 1 < len(visible) and visible[after + 1]:
                    after += 1
            y = original_xy[:, 1]
            exits = y[left] < 0.05 * height and y[left] < y[before]
            enters = y[right] < 0.05 * height and y[right] < y[after]
            gap = slice(left + 1, right)
            if (exits and enters) or np.any(filled[gap] & (filled_xy[gap, 1] < 0)):
                filled[gap] = 0
    source = ["net" if kept[i] else ("interp" if filled[i] else "") for i in range(len(kept))]
    return filled_xy, filled, source


def apply_track(record: ClipRecord, xy: np.ndarray, visible: np.ndarray) -> ClipRecord:
    """Write the trajectory into record.frames[].shuttle."""
    for i, frame in enumerate(record.frames[: len(visible)]):
        if visible[i]:
            frame.shuttle = Shuttle(x=round(float(xy[i][0]), 1), y=round(float(xy[i][1]), 1),
                                    visible=1)  # fmt: skip
        else:
            frame.shuttle = Shuttle()
    return record


def write_tracking_csv(
    path: Path, xy: np.ndarray, visible: np.ndarray, source: list[str] | None = None
) -> None:
    """tracking.csv in the TrackNetV3 layout plus a debug `source` column."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(TRACKING_CSV_COLUMNS)
        for i, vis in enumerate(visible):
            x, y = xy[i] if vis else (0.0, 0.0)
            writer.writerow([i, int(vis), f"{x:.1f}", f"{y:.1f}", source[i] if source else ""])


def read_tracking_csv(
    path: Path,
    num_frames: int,
    *,
    step: int = 1,
    scale: tuple[float, float] = (1.0, 1.0),
) -> tuple[np.ndarray, np.ndarray]:
    """Read a TrackNetV3-style CSV (Frame/Visibility/X/Y or frame/visible/x/y columns).

    Upstream predict.py writes source frame numbers and source pixels. Pass the reader's
    frame `step` and the source-to-normalized pixel `scale` to map them onto the record;
    rows between kept frames are dropped.
    """
    xy = np.zeros((num_frames, 2))
    visible = np.zeros(num_frames, dtype=int)
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            row = {k.lower(): v for k, v in row.items()}
            source_frame = int(float(row["frame"]))
            if source_frame % step:
                continue
            i = source_frame // step
            if 0 <= i < num_frames:
                visible[i] = int(float(row.get("visible", row.get("visibility", 0))))
                xy[i] = float(row["x"]) * scale[0], float(row["y"]) * scale[1]
    return xy, visible


def track_arrays(record: ClipRecord) -> tuple[np.ndarray, np.ndarray]:
    """(xy, visible) arrays from record.frames[].shuttle; invisible frames are NaN."""
    n = len(record.frames)
    xy = np.full((n, 2), np.nan)
    visible = np.zeros(n, dtype=int)
    for i, frame in enumerate(record.frames):
        s = frame.shuttle
        if s is not None and s.visible and s.x is not None and s.y is not None:
            xy[i] = s.x, s.y
            visible[i] = 1
    return xy, visible
