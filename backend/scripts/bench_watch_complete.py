"""Measure the actual frame-by-frame Watch WebSocket with isolated temporary storage.

Example: python scripts/bench_watch_complete.py --video PATH --court doubles
    --corners X1 Y1 X2 Y2 X3 Y3 X4 Y4 --seconds 45 --parallel false

Includes server and in-process WebSocket round trips, but not Flutter display/network.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import statistics
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings


class ResourceSampler:
    """Best-effort resource samples; GPU memory is device-wide, not process VRAM."""

    def __init__(self):
        self.samples = []
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._sample, daemon=True)

    def _sample(self):
        try:
            import psutil

            process = psutil.Process(os.getpid())
            process.cpu_percent()
            psutil.cpu_percent()
        except ImportError:
            process = None
        while not self.stop_event.is_set():
            sample = {}
            if process is not None:
                memory = psutil.virtual_memory()
                sample.update(
                    cpu_percent=process.cpu_percent(),
                    rss_bytes=process.memory_info().rss,
                    system_cpu_percent=psutil.cpu_percent(),
                    system_memory_used_bytes=memory.used,
                    system_memory_percent=memory.percent,
                )
            try:
                command = [
                    "nvidia-smi",
                    "--query-gpu=utilization.gpu,utilization.memory,"
                    "memory.used,clocks.current.graphics,temperature.gpu,power.draw",
                    "--format=csv,noheader,nounits",
                ]
                result = subprocess.run(
                    command, capture_output=True, text=True, timeout=2, check=False
                )
                if result.returncode == 0:
                    values = result.stdout.strip().splitlines()[0].split(",")
                    for key, value in zip(
                        (
                            "gpu_percent",
                            "gpu_memory_percent",
                            "gpu_used_mib",
                            "gpu_clock_mhz",
                            "gpu_temperature_c",
                            "gpu_power_w",
                        ),
                        values,
                        strict=True,
                    ):
                        with contextlib.suppress(ValueError):
                            sample[key] = float(value.strip())
            except (OSError, subprocess.TimeoutExpired, IndexError, ValueError):
                pass
            if sample:
                self.samples.append(sample)
            self.stop_event.wait(1)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop_event.set()
        self.thread.join()

    def summary(self):
        keys = {key for item in self.samples for key in item}
        return {
            key: {"max": max(values), "median": statistics.median(values)}
            for key in sorted(keys)
            if (values := [sample[key] for sample in self.samples if key in sample])
        }


def p95(values):
    return round(sorted(values)[max(0, math.ceil(len(values) * 0.95) - 1)], 2) if values else None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--corners", type=float, nargs=8, required=True)
    parser.add_argument("--court", choices=("singles", "doubles"), default="singles")
    parser.add_argument("--seconds", type=float, default=45)
    parser.add_argument("--parallel", choices=("true", "false"), default="false")
    parser.add_argument(
        "--profile", action="store_true", help="enable per-frame diagnostic timings"
    )
    parser.add_argument(
        "--resources", action="store_true", help="sample GPU and optional psutil CPU"
    )
    parser.add_argument(
        "--warmup-frames",
        type=int,
        default=0,
        help="run a previous session in the same process before measuring",
    )
    parser.add_argument("--out", type=Path, help="optional JSON output path")
    parser.add_argument(
        "--prefetch-depth",
        type=int,
        choices=(0, 2),
        default=0,
        help="benchmark-only decoded-frame queue; 0 disables it",
    )
    args = parser.parse_args()
    if args.prefetch_depth:
        from shuttlesense.io import FrameReader
        from shuttlesense.io.prefetch import PrefetchFrames

        # Process-local experiment only: production Watch retains its normal reader.
        FrameReader.__iter__ = lambda reader: PrefetchFrames(
            lambda: reader.frames(0, len(reader)), args.prefetch_depth
        )
    with tempfile.TemporaryDirectory(prefix="shuttlesense-complete-bench-") as temp:
        app = create_app(Settings(storage_dir=Path(temp), device="cuda"))
        with TestClient(app) as client:
            app.state.jobs.config.setdefault("watch", {})["frame_parallel_perception"] = (
                args.parallel == "true"
            )
            with args.video.open("rb") as source:
                response = client.post("/videos", files={"file": (args.video.name, source)})
            response.raise_for_status()
            video_id = response.json()["id"]
            corners = [args.corners[i : i + 2] for i in range(0, 8, 2)]
            if args.warmup_frames > 0:
                with client.websocket_connect("/watch") as warm:
                    warm.send_json(
                        {
                            "type": "start",
                            "video_id": video_id,
                            "court": args.court,
                            "corners": corners,
                            "playback": "complete",
                        }
                    )
                    warm_started = warm.receive_json()
                    if warm_started.get("type") != "started":
                        raise RuntimeError(str(warm_started))
                    for _ in range(min(args.warmup_frames, warm_started["frames"])):
                        warm.send_json({"type": "next"})
                        if warm.receive_json().get("type") != "video_frame":
                            raise RuntimeError("warmup frame failed")
                    warm.send_json({"type": "stop"})
                    saved_warm = warm.receive_json()
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    status = client.get(f"/jobs/{saved_warm['job_id']}").json()
                    if status["status"] in ("done", "failed"):
                        if status["status"] == "failed":
                            raise RuntimeError(f"warmup export failed: {status.get('error')}")
                        break
                    time.sleep(0.1)
                else:
                    raise TimeoutError("warmup export did not complete")
            started = time.perf_counter()
            sampler = ResourceSampler() if args.resources else contextlib.nullcontext()
            with sampler as resources, client.websocket_connect("/watch") as ws:
                ws.send_json(
                    {
                        "type": "start",
                        "video_id": video_id,
                        "court": args.court,
                        "corners": corners,
                        "playback": "complete",
                        "profile_diagnostics": args.profile,
                    }
                )
                first = ws.receive_json()
                if first.get("type") != "started":
                    raise RuntimeError(str(first))
                setup = time.perf_counter() - started
                count = 0
                frame_times = []
                stages = {"read": [], "jpeg": [], "processing": []}
                details = {}
                checkpoint = None
                while (
                    args.seconds <= 0 or time.perf_counter() - started < args.seconds
                ) and count < first["frames"]:
                    frame_start = time.perf_counter()
                    ws.send_json({"type": "next"})
                    frame = ws.receive_json()
                    frame_times.append((time.perf_counter() - frame_start) * 1000)
                    if frame.get("type") != "video_frame" or frame["index"] != count:
                        raise RuntimeError(f"Unexpected frame: {frame.get('type')}")
                    count += 1
                    if checkpoint is None and time.perf_counter() - started >= 45:
                        checkpoint = {
                            "elapsed_s": round(time.perf_counter() - started, 2),
                            "video_s": round(count / first["fps"], 2),
                        }
                    for name in stages:
                        value = (frame.get("timing_ms") or {}).get(name)
                        if value is not None:
                            stages[name].append(value)
                    for name, value in (frame.get("profile_ms") or {}).items():
                        details.setdefault(name, []).append(value)
                elapsed = time.perf_counter() - started
                ws.send_json({"type": "stop"})
                saved = ws.receive_json()
                if saved.get("type") != "saved" or not saved.get("job_id"):
                    raise RuntimeError(f"Save failed: {saved}")
            export_start = time.perf_counter()
            deadline = export_start + 120
            while time.perf_counter() < deadline:
                job = client.get(f"/jobs/{saved['job_id']}").json()
                if job["status"] in ("done", "failed"):
                    break
                time.sleep(0.1)
            else:
                raise TimeoutError("export did not complete")
            if job["status"] != "done":
                raise RuntimeError(f"export failed: {job.get('error')}")
            report = {
                "parallel": args.parallel == "true",
                "setup_s": round(setup, 2),
                "prefetch_depth": args.prefetch_depth,
                "profile": args.profile,
                "warmup_frames": args.warmup_frames,
                "elapsed_s": round(elapsed, 2),
                "frames": count,
                "video_s": round(count / first["fps"], 2),
                "completed": count == first["frames"],
                "checkpoint_45s": checkpoint,
                "normalized_fps_per_wall_s": round(count / elapsed, 2),
                "median_round_trip_ms": round(statistics.median(frame_times), 2)
                if frame_times
                else None,
                "p95_round_trip_ms": p95(frame_times),
                "median_stage_ms": {
                    name: round(statistics.median(values), 2)
                    for name, values in stages.items()
                    if values
                },
                "profile_medians": {
                    name: round(statistics.median(values), 2)
                    for name, values in details.items()
                    if values
                },
                "profile_p95": {name: p95(values) for name, values in details.items() if values},
                "resources": resources.summary() if resources else None,
                "export_after_saved_s": round(time.perf_counter() - export_start, 2),
                "providers": first.get("provider_diagnostics"),
                "stages": first.get("stages"),
            }
            rendered = json.dumps(report, indent=2)
            if args.out:
                args.out.parent.mkdir(parents=True, exist_ok=True)
                args.out.write_text(rendered + "\n", encoding="utf-8")
            print(rendered, flush=True)


if __name__ == "__main__":
    main()
