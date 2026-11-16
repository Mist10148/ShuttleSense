"""TrackNetV3 inference on normalized clip frames.

The pinned upstream model uses 512x288 RGB frames, a checkpoint-defined sequence
length and background mode, and one heatmap per frame. Its ``predict.py`` writes
source-frame pixels; this wrapper scales coordinates to normalized-video pixels.
"""

from __future__ import annotations

import logging
import sys
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext, StageSkipped
from shuttlesense.tracking.postprocess import (
    apply_track,
    heatmap_to_xy,
    read_tracking_csv,
    rectify,
    scale_to_video,
    write_tracking_csv,
)

TRACKNET_DIR = BACKEND_DIR / "third_party" / "TrackNetV3"
INPUT_SIZE = (512, 288)
_MODELS: dict[tuple[str, str, int], tuple[Any, int, str]] = {}
log = logging.getLogger(__name__)


def _tracknet_path() -> None:
    if not (TRACKNET_DIR / "model.py").is_file():
        raise StageSkipped("TrackNetV3 submodule is missing; run git submodule update --init")
    path = str(TRACKNET_DIR)
    if path not in sys.path:
        sys.path.insert(0, path)


def _load_model(path: Path, device: str, kind: str) -> tuple[Any, int, str]:
    import torch

    key = (str(path.resolve()), device, path.stat().st_mtime_ns)
    if key in _MODELS:
        return _MODELS[key]
    _tracknet_path()
    from model import InpaintNet, TrackNet

    checkpoint = torch.load(path, map_location=device, weights_only=True)
    params = checkpoint["param_dict"]
    seq_len = int(params["seq_len"])
    bg_mode = str(params.get("bg_mode", "")) if kind == "tracknet" else ""
    if kind == "tracknet":
        channels = seq_len * {"subtract": 1, "subtract_concat": 4}.get(bg_mode, 3)
        if bg_mode == "concat":
            channels += 3
        model = TrackNet(in_dim=channels, out_dim=seq_len)
    else:
        model = InpaintNet()
    model.load_state_dict(checkpoint["model"])
    model.to(device).eval()
    _MODELS[key] = model, seq_len, bg_mode
    return _MODELS[key]


def _background(reader: Any, count: int = 100) -> np.ndarray:
    """Approximate upstream's median background with evenly sampled frames."""
    samples = []
    for index in np.linspace(0, len(reader) - 1, min(count, len(reader)), dtype=int):
        frame = reader.read(int(index))
        if frame is not None:
            samples.append(frame[:, :, ::-1])
    if not samples:
        raise ValueError("video has no readable frames")
    return np.median(np.stack(samples), axis=0).astype(np.uint8)


def _track_input(frames: list[np.ndarray], bg_mode: str, median: np.ndarray | None) -> np.ndarray:
    import cv2

    return _track_input_rgb(
        [cv2.resize(frame[:, :, ::-1], INPUT_SIZE) for frame in frames], bg_mode, median
    )


def _track_input_rgb(
    frames: list[np.ndarray], bg_mode: str, median: np.ndarray | None
) -> np.ndarray:
    """Build identical model input from already-resized RGB frames."""
    import cv2

    channels = []
    bg = None if median is None else cv2.resize(median, INPUT_SIZE)
    for rgb in frames:
        if bg_mode in ("subtract", "subtract_concat"):
            diff = np.abs(rgb.astype(np.int16) - bg.astype(np.int16)).sum(axis=2)
            diff = np.clip(diff, 0, 255)[None]
            channels.append(
                diff
                if bg_mode == "subtract"
                else np.concatenate((rgb.transpose(2, 0, 1), diff), axis=0)
            )
        else:
            channels.append(rgb.transpose(2, 0, 1))
    if bg_mode == "concat":
        channels.insert(0, bg.transpose(2, 0, 1))
    return np.concatenate(channels).astype(np.float32) / 255.0


def _inpaint_mask(xy: np.ndarray, visible: np.ndarray, height: int) -> np.ndarray:
    """Mask internal gaps with plausible endpoints below the image's top 5 percent."""
    mask = np.zeros(len(visible), dtype=np.float32)
    good = np.flatnonzero(visible)
    for left, right in zip(good[:-1], good[1:], strict=False):
        if right > left + 1 and xy[left, 1] > height * 0.05 and xy[right, 1] > height * 0.05:
            mask[left + 1 : right] = 1
    return mask


def track_windows(
    model: Any,
    windows: list[list[np.ndarray]],
    bg_mode: str,
    median: np.ndarray | None,
    device: str,
    frame_size: tuple[int, int],
    *,
    prepared_rgb: bool = False,
    latest_only: bool = False,
) -> list[list[tuple[float, float, int]]]:
    """Shuttle (x, y, visible) in frame pixels for every frame of each seq_len window.

    Shared by the offline stage (non-overlapping windows) and live sessions (a sliding
    window over the newest frames). Call inside torch.inference_mode().
    """
    import torch

    prepare = _track_input_rgb if prepared_rgb else _track_input
    batch = torch.from_numpy(np.stack([prepare(w, bg_mode, median) for w in windows]))
    with torch.autocast("cuda", enabled=device.startswith("cuda")):
        heatmaps = model(batch.to(device))
        if latest_only:
            heatmaps = heatmaps[:, -1:]
        heatmaps = heatmaps.float().cpu().numpy()
    out = []
    for sequence in heatmaps:
        points = []
        # Watch consumes only the newest point. Inference remains identical, but
        # decoding old heatmaps in the overlapping window is unnecessary.
        for heatmap in sequence:
            x, y, vis = heatmap_to_xy(heatmap)
            if vis:
                px = scale_to_video(np.array([[x, y]]), INPUT_SIZE, frame_size)[0]
                points.append((float(px[0]), float(px[1]), 1))
            else:
                points.append((0.0, 0.0, 0))
        out.append(points)
    return out


def predict(ctx: StageContext, weights: Path) -> tuple[np.ndarray, np.ndarray, list[str]]:
    """Return (xy, visible, source) for each normalized frame."""
    import torch

    reader = ctx.reader
    if reader is None:
        raise ValueError("tracking requires an initialized frame reader")
    cfg = ctx.stage_config("tracking")
    model, seq_len, bg_mode = _load_model(weights, ctx.device, "tracknet")
    batch_size = max(1, int(cfg.get("batch_size", 16)))
    n = len(reader)
    xy = np.zeros((n, 2), dtype=float)
    visible = np.zeros(n, dtype=int)
    source = [""] * n
    median = _background(reader) if bg_mode else None

    # Non-overlapping windows bound memory. Only the final window is padded.
    with torch.inference_mode():
        for start in range(0, n, seq_len * batch_size):
            inputs, starts = [], []
            for window_start in range(start, min(start + seq_len * batch_size, n), seq_len):
                frames = reader.batch(window_start, seq_len)
                if not frames:
                    break
                frames.extend([frames[-1]] * (seq_len - len(frames)))
                inputs.append(frames)
                starts.append(window_start)
            if not inputs:
                break
            size = (reader.width, reader.height)
            results = track_windows(model, inputs, bg_mode, median, ctx.device, size)
            for window_start, points in zip(starts, results, strict=True):
                for offset, (x, y, vis) in enumerate(points):
                    i = window_start + offset
                    if i >= n:
                        break
                    if vis:
                        xy[i] = (x, y)
                        visible[i] = 1
                        source[i] = "net"
            ctx.progress(min(0.9, 0.9 * (start + len(inputs) * seq_len) / n))

        if cfg.get("use_inpaintnet", False):
            inpaint_path = BACKEND_DIR / cfg.get(
                "inpaintnet_weights", "weights/tracknet/InpaintNet_best.pt"
            )
            if not inpaint_path.is_file():
                log.warning("InpaintNet weights missing; keeping raw TrackNet detections")
            else:
                inpaint, inpaint_len, _ = _load_model(inpaint_path, ctx.device, "inpaintnet")
                mask = _inpaint_mask(xy, visible, reader.height)
                if np.any(mask):
                    normalized = xy / np.array([reader.width, reader.height])
                    for start in range(0, n, inpaint_len * batch_size):
                        inputs, masks, starts = [], [], []
                        for window_start in range(
                            start, min(start + inpaint_len * batch_size, n), inpaint_len
                        ):
                            end = min(window_start + inpaint_len, n)
                            coords = np.zeros((inpaint_len, 2), dtype=np.float32)
                            gap = np.zeros((inpaint_len, 1), dtype=np.float32)
                            coords[: end - window_start] = normalized[window_start:end]
                            gap[: end - window_start, 0] = mask[window_start:end]
                            inputs.append(coords)
                            masks.append(gap)
                            starts.append(window_start)
                        result = inpaint(
                            torch.from_numpy(np.stack(inputs)).to(ctx.device),
                            torch.from_numpy(np.stack(masks)).to(ctx.device),
                        )
                        for window_start, coords in zip(
                            starts, result.float().cpu().numpy(), strict=True
                        ):
                            for offset, point in enumerate(coords):
                                i = window_start + offset
                                if i >= n:
                                    break
                                if mask[i] and np.all(point > 0) and np.all(point <= 1):
                                    xy[i] = point * [reader.width, reader.height]
                                    visible[i] = 1
                                    source[i] = "inpaint"
                        ctx.progress(
                            min(0.99, 0.9 + 0.09 * (start + len(inputs) * inpaint_len) / n)
                        )
    # Hand the GPU memory back before the pose stage runs (6 GB on the team laptop).
    model = inpaint = None
    if str(ctx.device).startswith("cuda"):
        torch.cuda.empty_cache()
    return xy, visible, source


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill shuttle observations and write tracking.csv."""
    cfg = ctx.stage_config("tracking")
    n = len(record.frames)
    precomputed = cfg.get("precomputed_csv")
    if precomputed:
        path = BACKEND_DIR / precomputed
        if not path.exists():
            raise FileNotFoundError(f"precomputed tracking CSV not found: {path}")
        step, scale = 1, (1.0, 1.0)
        reader = ctx.reader
        if reader is not None and cfg.get("precomputed_space", "source") == "source":
            step = reader.step
            scale = (reader.width / reader.source.width, reader.height / reader.source.height)
        xy, visible = read_tracking_csv(path, n, step=step, scale=scale)
        source = ["net" if v else "" for v in visible]
    else:
        try:
            import torch  # noqa: F401
        except ImportError as exc:
            raise StageSkipped("torch is not installed") from exc
        weights = BACKEND_DIR / cfg.get("tracknet_weights", "weights/tracknet/TrackNet_best.pt")
        if not weights.exists():
            raise StageSkipped(f"missing weights: {weights.name}")
        xy, visible, source = predict(ctx, weights)

    xy, visible, post_source = rectify(
        xy, visible, max_gap=cfg.get("max_gap_frames", 8), outlier_px=cfg.get("outlier_px", 80)
    )
    source = [source[i] if post_source[i] == "net" else post_source[i] for i in range(n)]
    apply_track(record, xy, visible)
    write_tracking_csv(ctx.out_dir / "tracking.csv", xy, visible, source)
    ctx.progress(1.0)
    return record
