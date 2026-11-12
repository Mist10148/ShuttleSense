"""Replay a video into WS /live as if it were a camera, and report latency (T8.7, T8.12).

    python -m shuttlesense.live_replay --url ws://127.0.0.1:8000/live --video ../samples/rally01.mp4
    python -m shuttlesense.live_replay --in-process --fake --frames 300   # no server needed

Frames are sent one at a time and the next one only after the server's `frame` event for
it arrives, so the measured time is frame sent -> overlay event back (network + decode +
perception + analysis), without queueing. --realtime additionally paces frames at --fps.

Event lag is how late a decision arrives after the frame it is about: a hit after its
contact frame, a line call after its landing frame, a closed rally after its end frame. It
is reported in frames (the look-ahead the stages wait for, independent of the machine) and
in ms from sending that frame (meaningful with --realtime, where frames come at camera pace).
The websocket client comes with uvicorn[standard] (requirements/base.txt).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlsplit

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
        return json.loads(self.ws.recv(timeout=90))

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
    require_models: bool = False,
) -> dict[str, Any]:
    """Drive one session; return latency percentiles and event counts."""
    from shuttlesense.stream.fake_source import encode

    conn.send_json({"type": "start", "fps": fps, "width": width, "height": height,
                    "corners": corners, "name": "live replay"})  # fmt: skip
    started = conn.receive_json()
    if started["type"] != "started":
        raise RuntimeError(f"server refused the session: {started}")
    if require_models and not model_backed(started["stages"]):
        conn.send_json({"type": "stop"})
        conn.receive_json()
        raise ValueError("strict model benchmark needs real tracking and pose")
    # The server caps the rate (live.max_fps); send only the frames it keeps, stamped with
    # their video time, so every sent frame gets its frame event back.
    step = fps / float(started["fps"])
    latencies, server_ms, counts = [], [], {}
    sent_at: dict[int, float] = {}  # server frame -> when it was sent
    lags: dict[str, dict[str, list[float]]] = {}
    current = -1  # newest server frame with its frame event back
    t0, wall0 = time.perf_counter(), time.time() * 1000
    kept = -1
    for i, frame in enumerate(frames):
        # Match the server's nearest-slot rule, including halfway ties. Flooring
        # here sends duplicates into the same slot at non-integer rate ratios.
        slot = math.ceil(i / step - 0.5 - 1e-9)
        if slot == kept:
            continue
        kept = slot
        if realtime:
            delay = t0 + i / fps - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        sent = time.perf_counter()
        conn.send_bytes(encode(frame, i, wall0 + i * 1000 / fps))
        while True:
            event = conn.receive_json()
            counts[event["type"]] = counts.get(event["type"], 0) + 1
            ref = _event_frame(event)
            if ref is not None and ref in sent_at:
                lag = lags.setdefault(event["type"], {"frames": [], "ms": []})
                lag["frames"].append(current - ref)
                lag["ms"].append((time.perf_counter() - sent_at[ref]) * 1000)
            if event["type"] == "frame" and "frame" in event:
                current = max(current, int(event["frame"]))
                sent_at.setdefault(int(event["frame"]), sent)
            if event["type"] == "frame" and event.get("client_frame") == i:
                latencies.append((time.perf_counter() - sent) * 1000)
                if "latency_ms" in event:
                    server_ms.append(event["latency_ms"])
                break
            if event["type"] == "error":
                if event.get("code") == "bad_frame":
                    break  # no frame event follows a frame the server could not decode
                raise RuntimeError(f"server error: {event}")
    elapsed = time.perf_counter() - t0
    conn.send_json({"type": "stop"})
    while (event := conn.receive_json())["type"] != "saved":
        counts[event["type"]] = counts.get(event["type"], 0) + 1
    if require_models and not server_ms:
        raise ValueError("strict model benchmark received no analyzed frame samples")
    return {
        "frames": len(latencies),
        "stages": started["stages"],
        "round_trip_ms": _pcts(latencies),
        "server_ms": _pcts(server_ms),
        "throughput_fps": round(len(latencies) / elapsed, 1) if elapsed else 0.0,
        "event_lag": {
            kind: {"count": len(v["frames"]), "frames": _pcts(v["frames"]), "ms": _pcts(v["ms"])}
            for kind, v in sorted(lags.items())
        },
        "fps": float(started["fps"]),
        "events": counts,
        "job_id": event["job_id"],
    }


def model_backed(stages: dict) -> bool:
    return not stages.get("synthetic") and all(
        stages.get(stage) is True for stage in ("tracking", "pose")
    )


def _with_token(url: str, token: str | None) -> str:
    if token is None:
        return url
    parts = urlsplit(url)
    query = [(key, value) for key, value in parse_qsl(parts.query) if key != "token"]
    return parts._replace(query=urlencode([*query, ("token", token)])).geturl()


def _event_frame(event: dict) -> int | None:
    """The frame a decision event is about (None for frame, score and status events)."""
    kind = event.get("type")
    if kind == "hit":
        return int(event["hit"]["frame"])
    if kind == "line_call":
        return None if event["line_call"].get("override") else int(event["line_call"]["frame"])
    if kind == "rally" and event.get("rally"):
        return int(event["rally"]["end_frame"])
    return None


def _pcts(values: list[float]) -> dict[str, float]:
    if not values:
        return {}
    return {f"p{q}": round(float(np.percentile(values, q)), 1) for q in (50, 95, 99)}


def _frames(args: argparse.Namespace) -> tuple[Iterator[np.ndarray], int, int, float]:
    """(frames, width, height, fps); --fps overrides the video's own rate."""
    from shuttlesense.stream.fake_source import blank_frames, video_frames

    if args.video:
        import cv2

        cap = cv2.VideoCapture(str(args.video))
        width, height = (
            int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
            int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
        )
        fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0)
        cap.release()
        return video_frames(args.video, args.frames), width, height, args.fps or fps or 30.0
    return blank_frames(args.frames or 300, 1280, 720), 1280, 720, args.fps or 30.0


def _wait_rendered(client: Any, job_id: str | None, timeout_s: float = 120.0) -> None:
    """Let the saved session finish rendering before its storage folder is removed."""
    deadline = time.monotonic() + timeout_s
    while job_id and time.monotonic() < deadline:
        if client.get(f"/jobs/{job_id}").json().get("status") in ("done", "failed"):
            return
        time.sleep(0.1)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--url", default="ws://127.0.0.1:8000/live")
    parser.add_argument("--token")
    parser.add_argument("--video", type=Path, help="video to replay (default: synthetic frames)")
    parser.add_argument("--frames", type=int, help="stop after this many frames")
    parser.add_argument("--fps", type=float, help="frame rate (default: the video's, else 30)")
    parser.add_argument("--corners", help="x1,y1,...,x4,y4 in video pixels")
    parser.add_argument("--realtime", action="store_true", help="pace frames at --fps")
    parser.add_argument("--in-process", action="store_true", help="start the API in-process")
    parser.add_argument("--fake", action="store_true", help="with --in-process: fake perception")
    parser.add_argument("--require-models", action="store_true")
    parser.add_argument("--json", type=Path, help="also write the results here")
    args = parser.parse_args(argv)

    frames, width, height, fps = _frames(args)
    corners = None
    if args.corners:
        v = [float(x) for x in args.corners.split(",")]
        corners = [v[i : i + 2] for i in range(0, 8, 2)]
    if args.in_process:
        import tempfile

        from fastapi.testclient import TestClient

        from shuttlesense.api.main import create_app
        from shuttlesense.api.settings import Settings

        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            settings = Settings(storage_dir=Path(tmp), fake_pipeline=args.fake)
            with TestClient(create_app(settings)) as client:
                with client.websocket_connect("/live") as ws:
                    result = run(ws, frames, fps=fps, width=width, height=height,
                                 corners=corners, realtime=args.realtime,
                                 require_models=args.require_models)  # fmt: skip
                _wait_rendered(client, result["job_id"])
    else:
        url = _with_token(args.url, args.token)
        conn = _WebsocketsConn(url)
        try:
            result = run(conn, frames, fps=fps, width=width, height=height,
                         corners=corners, realtime=args.realtime,
                         require_models=args.require_models)  # fmt: skip
        finally:
            conn.close()
    text = json.dumps(result, indent=2)
    print(text)
    if args.json:
        args.json.write_text(text + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
