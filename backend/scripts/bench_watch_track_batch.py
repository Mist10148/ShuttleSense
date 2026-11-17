"""Compare sequential and cross-frame TrackNet inference without changing Watch."""

from __future__ import annotations

import argparse
import statistics
import time
from collections import deque
from pathlib import Path

import cv2
import numpy as np
import torch

from shuttlesense.config import BACKEND_DIR, detect_device, load_config
from shuttlesense.io import FrameReader
from shuttlesense.tracking.postprocess import heatmap_to_xy
from shuttlesense.tracking.tracknet import INPUT_SIZE, _load_model, _track_input_rgb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--batch", type=int, default=4)
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    args = parser.parse_args()
    device = detect_device(args.device)
    cfg = load_config()["stages"]["tracking"]
    model, seq_len, bg_mode = _load_model(BACKEND_DIR / cfg["tracknet_weights"], device, "tracknet")
    reader = FrameReader(args.video)
    window, samples, tensors = deque(maxlen=seq_len), [], []
    median = None
    for _, frame in reader.frames(0, args.frames):
        if bg_mode and len(samples) < 30:
            samples.append(cv2.resize(frame, INPUT_SIZE)[:, :, ::-1])
            median = np.median(np.stack(samples), axis=0).astype(np.uint8)
        window.append(cv2.resize(frame[:, :, ::-1], INPUT_SIZE))
        frames = list(window)
        frames = [frames[0]] * (seq_len - len(frames)) + frames
        # Snapshot the per-frame background before constructing the next window.
        tensors.append(_track_input_rgb(frames, bg_mode, median))

    def run(batch_size):
        outputs, durations = [], []
        with torch.inference_mode(), torch.autocast("cuda", enabled=device.startswith("cuda")):
            for start in range(0, len(tensors), batch_size):
                batch = torch.from_numpy(np.stack(tensors[start : start + batch_size])).to(device)
                if device.startswith("cuda"):
                    torch.cuda.synchronize()
                before = time.perf_counter()
                result = model(batch).float().cpu().numpy()
                durations.append(time.perf_counter() - before)
                outputs.extend(heatmap_to_xy(heatmaps[-1]) for heatmaps in result)
        return outputs, durations

    if not tensors:
        raise SystemExit("No frames")
    run(1)  # warm the GPU
    single, single_time = run(1)
    batched, batch_time = run(max(1, args.batch))
    changed = sum(a != b for a, b in zip(single, batched, strict=True))
    print(f"frames={len(tensors)} batch={args.batch}, changed final detections={changed}")
    print(f"sequential forward {sum(single_time):.3f}s, batched forward {sum(batch_time):.3f}s")
    print(
        f"median per call: {statistics.median(single_time) * 1000:.2f}ms / "
        f"{statistics.median(batch_time) * 1000:.2f}ms"
    )


if __name__ == "__main__":
    main()
