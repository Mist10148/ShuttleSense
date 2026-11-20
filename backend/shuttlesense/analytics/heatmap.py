"""Court heatmaps (F10, D44): where each side stood during play, and where rallies landed.

Each in-rally frame adds 1 / fps seconds at a player's court position, spread over a
0.25 m grid by a Gaussian. The Gaussian is wider far from the camera, where a pixel covers
more court and the foot point is less certain. Frames outside rallies (waiting, fetching
the shuttle) and positions pinned to the clamp edge (true place unknown, somewhere beyond
it) are left out. Doubles partners are merged per side, as the app's minimap does. The
grid covers the court plus PLAYER_MARGIN_M, the extent positions are clamped to.

Written to heatmap.json next to summary.json (analytics/export.py). Units are seconds per
cell for players, landings per cell for landings; each grid sums to its total.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from shuttlesense.analytics.positions import PLAYER_MARGIN_M, clamped_mask
from shuttlesense.schema import ClipRecord, is_doubles

CELL_M = 0.25
SIGMA_NEAR_M = 0.30  # Gaussian spread at the near baseline ...
SIGMA_FAR_M = 0.45  # ... growing linearly to the far baseline
LANDING_SIGMA_M = 0.25
HEATMAP_VERSION = 1


def sigma_at(y_m: np.ndarray, length_m: float) -> np.ndarray:
    """Kernel width in metres at court depth y (0 = near baseline, length = far)."""
    t = np.clip(np.asarray(y_m, dtype=float) / max(length_m, 1e-6), 0.0, 1.0)
    return SIGMA_NEAR_M + (SIGMA_FAR_M - SIGMA_NEAR_M) * t


def grid_axes(
    size: tuple[float, float], margin: float = PLAYER_MARGIN_M, cell: float = CELL_M
) -> tuple[np.ndarray, np.ndarray]:
    """Cell centres across (x) and along (y) the court, in metres."""
    width, length = size
    cols = int(np.ceil((width + 2 * margin) / cell - 1e-9))
    rows = int(np.ceil((length + 2 * margin) / cell - 1e-9))
    return -margin + cell * (np.arange(cols) + 0.5), -margin + cell * (np.arange(rows) + 0.5)


def density(
    points: np.ndarray,
    weights: np.ndarray,
    sigmas: np.ndarray,
    xs: np.ndarray,
    ys: np.ndarray,
) -> np.ndarray:
    """(rows, cols) sum of one normalised Gaussian per point, scaled by its weight.

    Each kernel is normalised over the grid, so a point near the edge keeps its full
    weight and the grid sums to weights.sum().
    """
    grid = np.zeros((len(ys), len(xs)))
    if len(points) == 0:
        return grid
    for start in range(0, len(points), 2048):  # bounded memory on long clips
        p = points[start : start + 2048]
        s = sigmas[start : start + 2048][:, None]
        gx = np.exp(-0.5 * ((xs[None, :] - p[:, :1]) / s) ** 2)
        gy = np.exp(-0.5 * ((ys[None, :] - p[:, 1:2]) / s) ** 2)
        norm = gx.sum(1) * gy.sum(1)
        ok = norm > 0
        w = np.where(ok, weights[start : start + 2048] / np.where(ok, norm, 1.0), 0.0)
        grid += gy.T @ (gx * w[:, None])
    return grid


def in_rally_mask(record: ClipRecord) -> np.ndarray:
    """(N,) True for frames inside a rally; every frame when the record has no rallies."""
    n = len(record.frames)
    if not record.rallies:
        return np.ones(n, dtype=bool)
    mask = np.zeros(n, dtype=bool)
    for r in record.rallies:
        mask[max(0, r.start_frame) : min(n, r.end_frame + 1)] = True
    return mask


def _side_samples(
    record: ClipRecord, side: str, mask: np.ndarray, size: tuple[float, float]
) -> np.ndarray:
    slots = (side, f"{side}_2") if is_doubles(record) else (side,)
    pts = []
    for i, f in enumerate(record.frames):
        if not mask[i] or f.court_positions is None:
            continue
        for slot in slots:
            p = getattr(f.court_positions, slot, None)
            if p is not None:
                pts.append(p)
    arr = np.asarray(pts, dtype=float).reshape(-1, 2)
    return arr[~clamped_mask(arr, size, PLAYER_MARGIN_M)]


def _peak(grid: np.ndarray, xs: np.ndarray, ys: np.ndarray) -> list[float] | None:
    if grid.max() <= 0:
        return None
    r, c = np.unravel_index(int(np.argmax(grid)), grid.shape)
    return [round(float(xs[c]), 3), round(float(ys[r]), 3)]


def build_heatmap(record: ClipRecord) -> dict[str, Any] | None:
    """heatmap.json content, or None without a calibrated court."""
    if record.court is None:
        return None
    size = (float(record.court.court_size_m[0]), float(record.court.court_size_m[1]))
    xs, ys = grid_axes(size)
    fps = float(record.fps or 30.0)
    mask = in_rally_mask(record)
    out: dict[str, Any] = {
        "version": HEATMAP_VERSION,
        "cell_m": CELL_M,
        "origin_m": [-PLAYER_MARGIN_M, -PLAYER_MARGIN_M],  # near-left corner of cell [0][0]
        "cols": len(xs),
        "rows": len(ys),
        "court_size_m": list(size),
        "sigma_m": {"near_baseline": SIGMA_NEAR_M, "far_baseline": SIGMA_FAR_M},
        "fps": fps,
        "in_rally_only": bool(record.rallies),
        "players": {},
    }
    for side in ("near", "far"):
        pts = _side_samples(record, side, mask, size)
        grid = density(pts, np.full(len(pts), 1.0 / fps), sigma_at(pts[:, 1], size[1]), xs, ys)
        out["players"][side] = {
            "seconds": round(float(len(pts) / fps), 3),
            "peak_m": _peak(grid, xs, ys),
            "grid": np.round(grid, 5).tolist(),  # rows from the near end, seconds per cell
        }
    landings = np.asarray(
        [(r.landing.x_m, r.landing.y_m) for r in record.rallies if r.landing is not None],
        dtype=float,
    ).reshape(-1, 2)
    inside = (
        (landings[:, 0] >= -PLAYER_MARGIN_M)
        & (landings[:, 0] <= size[0] + PLAYER_MARGIN_M)
        & (landings[:, 1] >= -PLAYER_MARGIN_M)
        & (landings[:, 1] <= size[1] + PLAYER_MARGIN_M)
    )
    landings = landings[inside]
    grid = density(
        landings, np.ones(len(landings)), np.full(len(landings), LANDING_SIGMA_M), xs, ys
    )
    out["landings"] = {
        "count": len(landings),
        "peak_m": _peak(grid, xs, ys),
        "grid": np.round(grid, 5).tolist(),  # landings per cell
    }
    return out
