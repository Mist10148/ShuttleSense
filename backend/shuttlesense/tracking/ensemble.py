"""Temporal ensemble for offline TrackNetV3: average each frame over overlapping windows.

TrackNetV3 predicts one heatmap per frame of a `seq_len` window. With non-overlapping
windows every frame is predicted once, and frames at a window's edge see the shuttle's
motion on one side only. Upstream `predict.py` defaults to sliding the window and averaging
the heatmaps a frame receives, weighting the middle of each window most (`--eval_mode
weight`). This module does the same for uploads; live and Watch sessions keep their own
sliding window in `stream/perception.py` and are not affected.

Memory stays bounded: a frame's summed heatmap is decoded and dropped as soon as no later
window can reach it.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

import numpy as np

from shuttlesense.tracking.postprocess import heatmap_to_xy, scale_to_video


def ensemble_weights(seq_len: int) -> np.ndarray:
    """Upstream's `weight` mode: a position counts by its distance to the window's edge."""
    index = np.arange(seq_len)
    weights = np.minimum(index + 1, seq_len - index).astype(np.float32)
    return weights / weights.sum()


def window_starts(n: int, seq_len: int, stride: int) -> list[int]:
    """Window starts covering frames 0..n-1; the last windows are padded by the caller."""
    stride = max(1, min(int(stride), seq_len))
    return list(range(0, n, stride))


def track_overlapping(
    model: Any,
    reader: Any,
    *,
    seq_len: int,
    stride: int,
    batch_size: int,
    device: str,
    prepare: Callable[[list[np.ndarray]], np.ndarray],
    input_size: tuple[int, int],
    progress: Callable[[float], None] | None = None,
) -> tuple[np.ndarray, np.ndarray]:
    """(xy, visible) in normalized-video pixels from heatmaps averaged across windows.

    `prepare` turns one window of frames into the model's input array. Call inside
    torch.inference_mode().
    """
    import torch

    n = len(reader)
    xy = np.zeros((n, 2), dtype=float)
    visible = np.zeros(n, dtype=int)
    weights = ensemble_weights(seq_len)
    starts = window_starts(n, seq_len, stride)
    size = (reader.width, reader.height)
    total: dict[int, np.ndarray] = {}
    weight_sum: dict[int, float] = {}

    def finish(before: int) -> None:
        for i in sorted(k for k in total if k < before):
            x, y, vis = heatmap_to_xy(total.pop(i) / weight_sum.pop(i))
            if vis:
                xy[i] = scale_to_video(np.array([[x, y]]), input_size, size)[0]
                visible[i] = 1

    for first in range(0, len(starts), batch_size):
        chunk = starts[first : first + batch_size]
        inputs = []
        for window_start in chunk:
            frames = reader.batch(window_start, seq_len)
            if not frames:
                break
            frames.extend([frames[-1]] * (seq_len - len(frames)))
            inputs.append(prepare(frames))
        if not inputs:
            break
        batch = torch.from_numpy(np.stack(inputs))
        with torch.autocast("cuda", enabled=str(device).startswith("cuda")):
            heatmaps = model(batch.to(device)).float().cpu().numpy()
        for window_start, sequence in zip(chunk, heatmaps, strict=False):
            for offset, heatmap in enumerate(sequence):
                i = window_start + offset
                if i >= n:
                    break
                weighted = heatmap * weights[offset]
                if i in total:
                    total[i] += weighted
                    weight_sum[i] += float(weights[offset])
                else:
                    total[i] = weighted
                    weight_sum[i] = float(weights[offset])
        done = first + len(inputs)
        # Frames before the next window's start can no longer change.
        finish(starts[done] if done < len(starts) else n)
        if progress is not None:
            progress(min(0.9, 0.9 * done / len(starts)))
    finish(n)
    return xy, visible
