"""Compare actual Watch WebSocket processing with an artificial shuttle bypass.

Run in a dedicated process and isolated storage only. The bypass changes analysis
results; it is a diagnostic intervention, not an inference implementation.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path

from fastapi.testclient import TestClient

from shuttlesense.api.main import create_app
from shuttlesense.api.settings import Settings
from shuttlesense.schema import Shuttle
from shuttlesense.stream.perception import ModelPerception


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--storage", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=100)
    parser.add_argument("--warmup", type=int, default=25)
    parser.add_argument("--corners", nargs=8, type=float, required=True)
    args = parser.parse_args()
    if args.frames < 1 or args.warmup < 1:
        parser.error("frames and warmup must be positive")
    app = create_app(Settings(storage_dir=args.storage, device="cuda"))
    original = ModelPerception._shuttle
    skip_shuttle = False

    def shuttle(self, frame):
        return Shuttle() if skip_shuttle else original(self, frame)

    ModelPerception._shuttle = shuttle
    try:
        with TestClient(app) as client:
            with args.video.open("rb") as source:
                response = client.post("/videos", files={"file": (args.video.name, source)})
            response.raise_for_status()
            video_id = response.json()["id"]
            corners = [args.corners[i : i + 2] for i in range(0, 8, 2)]

            def run(count, bypass):
                nonlocal skip_shuttle
                skip_shuttle = bypass
                started = time.perf_counter()
                times = []
                with client.websocket_connect("/watch") as ws:
                    ws.send_json({"type": "start", "video_id": video_id, "court": "doubles",
                                  "corners": corners, "playback": "complete"})
                    initial = ws.receive_json()
                    if initial.get("type") != "started" or initial["frames"] < count:
                        raise RuntimeError(f"Unable to start required frames: {initial}")
                    setup = time.perf_counter() - started
                    for index in range(count):
                        before = time.perf_counter()
                        ws.send_json({"type": "next"})
                        frame = ws.receive_json()
                        times.append((time.perf_counter() - before) * 1000)
                        if frame.get("type") != "video_frame" or frame.get("index") != index:
                            raise RuntimeError(f"Unexpected frame: {frame.get('type')}")
                    before_stop = time.perf_counter()
                    ws.send_json({"type": "stop"})
                    saved = ws.receive_json()
                    if saved.get("type") != "saved" or not saved.get("job_id"):
                        raise RuntimeError(f"Save failed: {saved}")
                    saved_s = time.perf_counter() - started
                deadline = time.monotonic() + 120
                while time.monotonic() < deadline:
                    job = client.get(f"/jobs/{saved['job_id']}").json()
                    if job["status"] == "done":
                        break
                    if job["status"] == "failed":
                        raise RuntimeError(f"Export failed: {job.get('error')}")
                    time.sleep(0.1)
                else:
                    raise TimeoutError("Export did not complete")
                return {"mode": "bypass" if bypass else "normal", "frames": count,
                        "setup_s": round(setup, 3),
                        "processing_s": round(before_stop - started - setup, 3),
                        "saved_s": round(saved_s, 3),
                        "round_trip_median_ms": round(statistics.median(times), 3),
                        "round_trip_p95_ms": round(sorted(times)[(95 * count + 99) // 100 - 1], 3),
                        "job_id": saved["job_id"]}

            for mode in (False, True):
                print("WARMUP " + json.dumps(run(args.warmup, mode)), flush=True)
            # Counterbalance order: AB, BA, BA. All trials use fresh session state.
            for mode in (False, True, True, False, True, False):
                print("TRIAL " + json.dumps(run(args.frames, mode)), flush=True)
    finally:
        ModelPerception._shuttle = original


if __name__ == "__main__":
    main()
