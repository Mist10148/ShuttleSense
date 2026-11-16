"""Model-independent shuttle post-processing (F2): heatmaps to points, outliers, gaps, CSV.

Everything here is pure NumPy/OpenCV so it is tested without TrackNetV3 or a GPU.
"""

from __future__ import annotations

import csv
from pathlib import Path

import numpy as np

from shuttlesense.schema import ClipRecord, Shuttle
from shuttlesense.tracking.interpolate import interpolate_gaps

TRACKING_CSV_COLUMNS = ("frame", "visible", "x", "y", "source")


def heatmap_to_xy(heatmap: np.ndarray, threshold: float = 0.5) -> tuple[float, float, int]:
    """(x, y, visible) of the largest blob above `threshold` in a (H, W) heatmap.

    Coordinates are in heatmap pixels (blob centroid). Same rule as upstream TrackNetV3:
    binarize, keep the largest connected component.
    """
    import cv2

    mask = (heatmap >= threshold).astype(np.uint8)
    count, _labels, stats, centroids = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if count <= 1:  # label 0 is the background
        return 0.0, 0.0, 0
    best = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    x, y = centroids[best]
    return float(x), float(y), 1


def scale_to_video(
    xy: np.ndarray, from_size: tuple[int, int], to_size: tuple[int, int]
) -> np.ndarray:
    """Scale (N, 2) points from a (w, h) network input to (w, h) normalized video pixels."""
    sx = to_size[0] / from_size[0]
    sy = to_size[1] / from_size[1]
    return np.asarray(xy, dtype=float) * np.array([sx, sy])


def remove_outliers(
    xy: np.ndarray, visible: np.ndarray, outlier_px: float, window: int = 2
) -> np.ndarray:
    """Hide isolated detections: no visible neighbour within +-window frames and farther than
    `outlier_px` from the last kept point. Returns a new visible array."""
    visible = visible.astype(int).copy()
    n = len(visible)
    last: np.ndarray | None = None
    for i in range(n):
        if not visible[i]:
            continue
        lo, hi = max(0, i - window), min(n, i + window + 1)
        isolated = visible[lo:hi].sum() == 1
        if isolated and last is not None and np.hypot(*(xy[i] - last)) > outlier_px:
            visible[i] = 0
            continue
        last = xy[i]
    return visible


def rectify(
    xy: np.ndarray, visible: np.ndarray, *, max_gap: int, outlier_px: float
) -> tuple[np.ndarray, np.ndarray, list[str]]:
    """Outlier removal then short-gap interpolation. Returns (xy, visible, source per frame)
    where source is "net", "interp" or "" (invisible)."""
    kept = remove_outliers(xy, visible, outlier_px)
    filled_xy, filled = interpolate_gaps(xy, kept, max_gap)
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
