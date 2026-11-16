"""Summarize opt-in WATCH_PROFILE lines captured from a Flutter run."""
from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path


def summarize(rows):
    received = [row for row in rows if row.get("event") == "received"]
    checkpoints = [row for row in received if row.get("elapsed_ms", 0) >= 45_000]

    def values(event, key):
        return [row[key] for row in rows if row.get("event") == event
                and isinstance(row.get(key), (int, float))]

    def stats(items):
        if not items:
            return None
        return {"count": len(items), "median": round(statistics.median(items), 2),
                "p95": round(sorted(items)[math.ceil(len(items) * .95) - 1], 2)}

    checkpoint = checkpoints[0] if checkpoints else None
    if checkpoint and checkpoint.get("video_fps"):
        checkpoint = {"elapsed_s": round(checkpoint["elapsed_ms"] / 1000, 2),
                      "video_s": round((checkpoint["frame"] + 1) / checkpoint["video_fps"], 2)}
    else:
        checkpoint = None
    return {"frames_received": len(received), "checkpoint_45s": checkpoint,
            "round_trip_ms": stats(values("received", "round_trip_ms")),
            "json_ms": stats(values("received", "json_ms")),
            "handling_ms": stats(values("received", "handle_ms")),
            "next_request_delay_ms": stats(values("next", "since_response_ms")),
            "ui_callback_delay_ms": stats(values("ui_frame", "since_response_ms")),
            "analysis_saved_ms": values("analysis_saved", "elapsed_ms"),
            "clock_stopped_ms": values("clock_stopped", "elapsed_ms"),
            "stop_status": [row.get("status") for row in rows
                            if row.get("event") == "clock_stopped"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    sessions, current = [], None
    for line in args.log.read_text(encoding="utf-8", errors="replace").splitlines():
        marker = line.find("WATCH_PROFILE ")
        if marker < 0:
            continue
        try:
            row = json.loads(line[marker + len("WATCH_PROFILE "):])
        except json.JSONDecodeError:
            continue
        if row.get("event") == "start":
            current = []
            sessions.append(current)
        if current is not None:
            current.append(row)
    if not sessions:
        raise SystemExit("No complete WATCH_PROFILE start marker found")
    print(json.dumps([summarize(session) for session in sessions], indent=2))


if __name__ == "__main__":
    main()
