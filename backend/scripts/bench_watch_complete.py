"""Measure the actual frame-by-frame Watch WebSocket with isolated temporary storage.

Example: python scripts/bench_watch_complete.py --video PATH --court doubles
    --corners X1 Y1 X2 Y2 X3 Y3 X4 Y4 --seconds 45 --parallel false

Includes server and in-process WebSocket round trips, but not Flutter display/network.
"""
from __future__ import annotations

import argparse
import json
import statistics
import tempfile
import time
from pathlib import Path

from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--corners", type=float, nargs=8, required=True)
    parser.add_argument("--court", choices=("singles", "doubles"), default="singles")
    parser.add_argument("--seconds", type=float, default=45)
    parser.add_argument("--parallel", choices=("true", "false"), default="false")
    args = parser.parse_args()
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
            started = time.perf_counter()
            with client.websocket_connect("/watch") as ws:
                ws.send_json({"type": "start", "video_id": video_id, "court": args.court,
                              "corners": [args.corners[i:i+2] for i in range(0, 8, 2)],
                              "playback": "complete"})
                first = ws.receive_json()
                if first.get("type") != "started":
                    raise RuntimeError(str(first))
                setup = time.perf_counter() - started
                count = 0
                frame_times = []
                stages = {"read": [], "jpeg": [], "processing": []}
                while time.perf_counter() - started < args.seconds and count < first["frames"]:
                    frame_start = time.perf_counter()
                    ws.send_json({"type": "next"})
                    frame = ws.receive_json()
                    frame_times.append((time.perf_counter() - frame_start) * 1000)
                    if frame.get("type") != "video_frame" or frame["index"] != count:
                        raise RuntimeError(f"Unexpected frame: {frame.get('type')}")
                    count += 1
                    for name in stages:
                        value = (frame.get("timing_ms") or {}).get(name)
                        if value is not None:
                            stages[name].append(value)
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
                time.sleep(.1)
            else:
                raise TimeoutError("export did not complete")
            if job["status"] != "done":
                raise RuntimeError(f"export failed: {job.get('error')}")
            print(json.dumps({"parallel": args.parallel == "true", "setup_s": round(setup, 2),
                              "elapsed_s": round(elapsed, 2), "frames": count,
                              "video_s": round(count / first["fps"], 2),
                              "median_round_trip_ms": round(statistics.median(frame_times), 2)
                              if frame_times else None,
                              "median_stage_ms": {name: round(statistics.median(values), 2)
                                                  for name, values in stages.items() if values},
                              "export_after_saved_s": round(time.perf_counter()-export_start, 2),
                              "providers": first.get("provider_diagnostics"),
                              "stages": first.get("stages")}, indent=2), flush=True)


if __name__ == "__main__":
    main()
