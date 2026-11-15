"""Compare watch-only sequential and concurrent perception on a supplied video.

Run from backend: python scripts/bench_watch_parallel.py --video ../samples/rally01.mp4
Use representative labelled clips before enabling watch.parallel_perception.
"""

from __future__ import annotations

import argparse
import statistics
import time
from pathlib import Path

import numpy as np

from shuttlesense.config import detect_device, load_config
from shuttlesense.io import FrameReader
from shuttlesense.stream.perception import ModelPerception
from shuttlesense.stream.watch_parallel import ParallelWatchPerception


def run(reader, frames, device, parallel):
    import torch

    base = ModelPerception(load_config(), device, (reader.width, reader.height), None)
    if not all(base.available.values()):
        raise RuntimeError(f"Models unavailable: {base.available}")
    processor = ParallelWatchPerception(base) if parallel else base
    timings, observations = [], []
    try:
        for index, frame in reader.frames(0, min(len(reader), frames)):
            if device.startswith("cuda"):
                torch.cuda.synchronize()
            started = time.perf_counter()
            shuttle, players = processor(frame, index)
            if device.startswith("cuda"):
                torch.cuda.synchronize()
            timings.append((time.perf_counter() - started) * 1000)
            observations.append((shuttle.model_dump(), players.model_dump()))
    finally:
        if parallel:
            processor.close()
    return timings, observations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    args = parser.parse_args()
    reader = FrameReader(args.video)
    device = detect_device(args.device)
    sequential, a = run(reader, args.frames, device, False)
    concurrent, b = run(reader, args.frames, device, True)
    if not sequential or len(a) != len(b):
        raise SystemExit("Video has too few readable frames")
    # Exclude initial model warmup from timing, but include all frames in comparison.
    warmup = min(10, len(sequential) // 4)
    for label, values in [("sequential", sequential[warmup:]), ("concurrent", concurrent[warmup:])]:
        print(
            f"{label}: median {statistics.median(values):.1f} ms, p95 {np.percentile(values, 95):.1f} ms"
        )
    print(f"Frame outputs differing: {sum(x != y for x, y in zip(a, b, strict=True))}/{len(a)}")
    print(
        "Output differences need inspection against labelled footage; do not infer accuracy from speed."
    )


if __name__ == "__main__":
    main()
