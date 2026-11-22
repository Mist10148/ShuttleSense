"""Compare sequential/concurrent Watch perception with identical inputs and settings.

Runs isolated model perception, not Flutter, WebSocket, or end-to-end playback.
Device-wide GPU samples include other processes; Torch peaks exclude ORT allocations.
"""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path

import torch
from bench_watch_complete import ResourceSampler
from bench_watch_parallel import replay_analysis, run

from shuttlesense.config import detect_device, load_config
from shuttlesense.io import FrameReader


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--warmup", type=int, default=12)
    parser.add_argument("--corners", type=float, nargs=8, required=True)
    parser.add_argument("--device", choices=("cpu", "cuda"), default="cuda")
    args = parser.parse_args()
    if args.frames < 1 or args.warmup < 1:
        parser.error("frames and warmup must be positive")
    device = detect_device(args.device)
    reader = FrameReader(args.video)
    if len(reader) < max(args.frames, args.warmup):
        parser.error("video has too few normalized frames")
    sx, sy = reader.width / reader.source.width, reader.height / reader.source.height
    corners = [(args.corners[i] * sx, args.corners[i + 1] * sy) for i in range(0, 8, 2)]
    watch = load_config().get("watch", {})
    kwargs = {
        "corners": corners,
        "court": "doubles",
        "batch_size": int(watch.get("pose_batch_size", 1)),
        "candidate_filter": watch.get("candidate_filter", "off"),
        "player_provider": watch.get("player_provider", "cuda"),
        "jpeg_roundtrip": True,
    }

    def trial(parallel, count):
        if device.startswith("cuda"):
            torch.cuda.synchronize()
            torch.cuda.reset_peak_memory_stats()
        with ResourceSampler() as sampler:
            timings, observations, diagnostics = run(reader, count, device, parallel, **kwargs)
        peak = torch.cuda.max_memory_allocated() if device.startswith("cuda") else None
        if len(timings) != count or len(observations) != count:
            raise RuntimeError("incomplete frame sequence")
        return timings, observations, diagnostics, sampler.summary(), peak

    # Establish both model paths before alternating fresh session state.
    for parallel in (False, True):
        trial(parallel, args.warmup)
    results, reference = [], None
    for parallel in (False, True, True, False, True, False):
        times, observations, diagnostics, resources, torch_peak = trial(parallel, args.frames)
        if reference is None:
            reference = observations
        differences = sum(a != b for a, b in zip(reference, observations, strict=True))
        shuttle_differences = sum(
            a[0] != b[0] for a, b in zip(reference, observations, strict=True)
        )
        player_differences = sum(a[1] != b[1] for a, b in zip(reference, observations, strict=True))
        analysis = replay_analysis(observations, reader, device, corners, "doubles")
        if not results:
            reference_analysis = analysis
        result = {
            "mode": "concurrent" if parallel else "sequential",
            "frames": args.frames,
            "median_ms": round(statistics.median(times), 3),
            "p95_ms": round(sorted(times)[(95 * len(times) + 99) // 100 - 1], 3),
            "different_frames": differences,
            "different_shuttle_frames": shuttle_differences,
            "different_player_frames": player_differences,
            "analysis_equal_to_first": analysis == reference_analysis,
            "analysis_counts": {
                key: len(analysis[key]) for key in ("hits", "rallies", "line_calls")
            },
            "candidate_counts": (
                {key: diagnostics[key] for key in ("frames", "people", "eligible", "excluded")}
                if diagnostics
                else None
            ),
            "resources": resources,
            "torch_peak_allocated_bytes": torch_peak,
        }
        results.append(result)
        print("TRIAL " + json.dumps(result), flush=True)
    print(
        "COMPLETE "
        + json.dumps(
            {"device": device, "settings": kwargs | {"corners": corners}, "trials": len(results)}
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
