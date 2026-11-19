"""Capture an offline Watch CUDA trace with approximate model-call attribution.

Pass normal profile_watch_pipeline.py options after this script's --trace and --ranges
options. The capture includes initialization and adds substantial profiling overhead.
"""

from __future__ import annotations

import argparse
import inspect
import json
import runpy
import sys
import threading
import time
from pathlib import Path

import torch

import shuttlesense.stream.perception as perception_module
from shuttlesense.stream.perception import ModelPerception


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--ranges", required=True, type=Path)
    args, profile_args = parser.parse_known_args()
    ranges = []

    def wrap(obj, name, label):
        original = getattr(obj, name)

        def measured(*a, **kw):
            start = time.perf_counter_ns()
            try:
                return original(*a, **kw)
            finally:
                ranges.append(
                    {
                        "name": label,
                        "tid": threading.get_native_id(),
                        "start_ns": start,
                        "end_ns": time.perf_counter_ns(),
                    }
                )

        setattr(obj, name, measured)

    wrap(ModelPerception, "_shuttle", "shuttle")
    wrap(ModelPerception, "_players", "players")
    original_enable = perception_module.enable_watch_player_continuity

    def enable(model):
        original_enable(model)
        body = inspect.getclosurevars(model.watch_detect).nonlocals["body"]
        wrap(body.det_model, "inference", "detector")
        wrap(body.pose_model.session, "run", "pose")

    perception_module.enable_watch_player_continuity = enable
    script = Path(__file__).with_name("profile_watch_pipeline.py")
    sys.argv = [str(script), *profile_args]
    with torch.profiler.profile(
        activities=[torch.profiler.ProfilerActivity.CPU, torch.profiler.ProfilerActivity.CUDA]
    ) as profiler:
        with torch.profiler.record_function("watch_clock_anchor"):
            anchor_ns = time.perf_counter_ns()
        runpy.run_path(str(script), run_name="__main__")
    profiler.export_chrome_trace(str(args.trace))
    args.ranges.write_text(json.dumps({"anchor_ns": anchor_ns, "ranges": ranges}), encoding="utf8")


if __name__ == "__main__":
    main()
