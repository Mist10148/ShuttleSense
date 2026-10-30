"""Replay a video into WS /live as if it were a camera, and report latency (T8.7, T8.12).

    python -m shuttlesense.live_replay --url ws://127.0.0.1:8000/live --video ../samples/rally01.mp4
    python -m shuttlesense.live_replay --in-process --fake --frames 300   # no server needed

Frames are sent one at a time and the next one only after the server's `frame` event for
it arrives, so the measured time is frame sent -> overlay event back (network + decode +
perception + analysis), without queueing. --realtime additionally paces frames at --fps.
The websocket client comes with uvicorn[standard] (requirements/base.txt).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import numpy as np


class _WebsocketsConn:
    def __init__(self, url: str) -> None:
        from websockets.sync.client import connect

        self.ws = connect(url, max_size=None)

    def send_json(self, data: dict) -> None:
        self.ws.send(json.dumps(data))

    def send_bytes(self, data: bytes) -> None:
        self.ws.send(data)

    def receive_json(self) -> dict:
        return json.loads(self.ws.recv())

    def close(self) -> None:
        self.ws.close()


def run(
    conn: Any,
    frames: Iterator[np.ndarray],
    *,
    fps: float,
    width: int,
    height: int,
    corners: list | None = None,
    realtime: bool = False,
) -> dict[str, Any]:
    """Drive one session; return latency percentiles and event counts."""
    from shuttlesense.stream.fake_source import encode

    conn.send_json({"type": "start", "fps": fps, "width": width, "height": height,
                    "corners": corners, "name": "live replay"})  # fmt: skip
    started = conn.receive_json()
    if started["type"] != "started":
        raise RuntimeError(f"server refused the session: {started}")
    latencies, server_ms, counts = [], [], {}
    t0 = time.perf_counter()
    for i, frame in enumerate(frames):
        if realtime:
            delay = t0 + i / fps - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        sent = time.perf_counter()
        conn.send_bytes(encode(frame, i, time.time() * 1000))
        while True:
            event = conn.receive_json()
            counts[event["type"]] = counts.get(event["type"], 0) + 1
            if event["type"] == "frame" and event.get("client_frame") == i:
                latencies.append((time.perf_counter() - sent) * 1000)
                if "latency_ms" in event:
                    server_ms.append(event["latency_ms"])
                break
    elapsed = time.perf_counter() - t0
    conn.send_json({"type": "stop"})
    while (event := conn.receive_json())["type"] != "saved":
        counts[event["type"]] = counts.get(event["type"], 0) + 1
    return {
        "frames": len(latencies),
        "stages": started["stages"],
        "round_trip_ms": _pcts(latencies),
        "server_ms": _pcts(server_ms),
        "throughput_fps": round(len(latencies) / elapsed, 1) if elapsed else 0.0,
        "events": counts,
        "job_id": event["job_id"],
    }


def _pcts(values: list[float]) -> dict[str, float]:
    if not values:
        return {}
    return {f"p{q}": round(float(np.percentile(values, q)), 1) for q in (50, 95, 99)}


def _frames(args: argparse.Namespace) -> tuple[Iterator[np.ndarray], int, int]:
    from shuttlesense.stream.fake_source import blank_frames, video_frames

    if args.video:
        import cv2

        cap = cv2.VideoCapture(str(args.video))
        width, height = (
            int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
            int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
        )
        cap.release()
        return video_frames(args.video, args.frames), width, height
    return blank_frames(args.frames or 300, 1280, 720), 1280, 720


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--url", default="ws://127.0.0.1:8000/live")
    parser.add_argument("--token")
    parser.add_argument("--video", type=Path, help="video to replay (default: synthetic frames)")
    parser.add_argument("--frames", type=int, help="stop after this many frames")
    parser.add_argument("--fps", type=float, default=30.0)
    parser.add_argument("--corners", help="x1,y1,...,x4,y4 in video pixels")
    parser.add_argument("--realtime", action="store_true", help="pace frames at --fps")
    parser.add_argument("--in-process", action="store_true", help="start the API in-process")
    parser.add_argument("--fake", action="store_true", help="with --in-process: fake perception")
    parser.add_argument("--json", type=Path, help="also write the results here")
    args = parser.parse_args(argv)

    frames, width, height = _frames(args)
    corners = None
    if args.corners:
        v = [float(x) for x in args.corners.split(",")]
        corners = [v[i : i + 2] for i in range(0, 8, 2)]
    if args.in_process:
        import tempfile

        from fastapi.testclient import TestClient

        from shuttlesense.api.main import create_app
        from shuttlesense.api.settings import Settings

        with tempfile.TemporaryDirectory() as tmp:
            settings = Settings(storage_dir=Path(tmp), fake_pipeline=args.fake)
            with (
                TestClient(create_app(settings)) as client,
                client.websocket_connect("/live") as ws,
            ):
                result = run(ws, frames, fps=args.fps, width=width, height=height,
                             corners=corners, realtime=args.realtime)  # fmt: skip
    else:
        url = args.url + (f"?token={args.token}" if args.token else "")
        conn = _WebsocketsConn(url)
        try:
            result = run(conn, frames, fps=args.fps, width=width, height=height,
                         corners=corners, realtime=args.realtime)  # fmt: skip
        finally:
            conn.close()
    text = json.dumps(result, indent=2)
    print(text)
    if args.json:
        args.json.write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
