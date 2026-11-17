"""Measure and compare Watch shuttle input construction without concurrent player work."""

from __future__ import annotations

import argparse
import statistics
import time
from collections import defaultdict, deque
from pathlib import Path

import cv2
import numpy as np
import torch

from shuttlesense.config import BACKEND_DIR
from shuttlesense.io import FrameReader
from shuttlesense.tracking.tracknet import INPUT_SIZE, _load_model, _track_input_rgb
from shuttlesense.tracking.watch_gpu_window import WatchGpuWindow


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=120)
    args = parser.parse_args()
    model, count, mode = _load_model(
        BACKEND_DIR / "weights/tracknet/TrackNet_best.pt", "cuda", "tracknet"
    )
    if mode != "concat":
        raise RuntimeError("GPU window supports TrackNet concat background only")
    gpu = WatchGpuWindow(count, "cuda")
    window, backgrounds, timings = deque(maxlen=count), [], defaultdict(list)
    mismatch, heatmap_error = 0, 0.0
    for _, frame in FrameReader(args.video).frames(0, args.frames):
        ok, jpeg = cv2.imencode(".jpg", frame)
        if not ok:
            raise RuntimeError("JPEG encode failed")
        frame = cv2.imdecode(jpeg, cv2.IMREAD_COLOR)
        rgb = cv2.resize(frame[:, :, ::-1], INPUT_SIZE)
        if len(backgrounds) < 30:
            backgrounds.append(rgb)
            median = np.median(np.stack(backgrounds), axis=0).astype(np.uint8)
        window.append(rgb)
        padded = [window[0]] * (count - len(window)) + list(window)
        start = time.perf_counter()
        baseline = _track_input_rgb(padded, mode, median)[None]
        timings["cpu_prepare"].append((time.perf_counter() - start) * 1000)
        start = time.perf_counter()
        input_cuda = torch.from_numpy(baseline).to("cuda")
        torch.cuda.synchronize()
        timings["cpu_input_upload"].append((time.perf_counter() - start) * 1000)
        start = time.perf_counter()
        candidate = gpu.push(rgb, median)
        torch.cuda.synchronize()
        timings["gpu_window_update"].append((time.perf_counter() - start) * 1000)
        mismatch += int(not np.array_equal(input_cuda.cpu().numpy(), candidate.cpu().numpy()))
        with torch.inference_mode(), torch.autocast("cuda"):
            start = time.perf_counter()
            expected = model(input_cuda)[:, -1:].float().cpu().numpy()
            timings["pytorch_inference"].append((time.perf_counter() - start) * 1000)
            actual = model(candidate)[:, -1:].float().cpu().numpy()
        heatmap_error = max(heatmap_error, float(np.max(np.abs(expected - actual))))
    print(
        f"frames={len(timings['cpu_prepare'])}, input mismatches={mismatch}, "
        f"max heatmap difference={heatmap_error:.8g}"
    )
    for name, values in timings.items():
        warm = min(10, len(values) // 4)
        print(
            f"{name}: median={statistics.median(values[warm:]):.2f}ms "
            f"total={sum(values[warm:]) / 1000:.2f}s"
        )
    print("Isolated synchronized measurements; player inference and playback are not included.")


if __name__ == "__main__":
    main()
