"""Summarize opt-in WATCH_PROFILE lines captured from a Flutter run."""
from __future__ import annotations

import argparse
import json
import math
import statistics
from pathlib import Path


def summarize(rows, *, same_host=False):
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
    transports = [row["previous_transport"] for row in received
                  if isinstance(row.get("previous_transport"), dict)]
    server_stages = {
        key: [row["server_ms"][key] for row in received
              if isinstance(row.get("server_ms"), dict)
              and isinstance(row["server_ms"].get(key), (int, float))]
        for key in ("read", "jpeg", "processing")
    }
    paced = [row for row in received
             if isinstance(row.get("round_trip_ms"), (int, float))
             and isinstance(row.get("video_fps"), (int, float)) and row["video_fps"] > 0]
    paced_below_interval = sum(row["round_trip_ms"] < 1000 / row["video_fps"] for row in paced)
    read_pairs = [row for row in paced if isinstance(row.get("server_ms"), dict)
                  and isinstance(row["server_ms"].get("read"), (int, float))]
    # Idealized savings if every measured read were completely overlapped. The
    # playback interval still caps the benefit when round trips are very fast.
    cycle_ms = sum(max(row["round_trip_ms"], 1000 / row["video_fps"]) for row in read_pairs)
    overlap_ms = sum(min(max(row["server_ms"]["read"], 0),
                         max(row["round_trip_ms"] - 1000 / row["video_fps"], 0))
                     for row in read_pairs)
    delivery = [(row["client_receive_epoch_us"] - row["server_serialize_epoch_us"]) / 1000
                for row in received
                if same_host and isinstance(row.get("client_receive_epoch_us"), (int, float))
                and isinstance(row.get("server_serialize_epoch_us"), (int, float))
                and row["client_receive_epoch_us"] >= row["server_serialize_epoch_us"]]
    if checkpoint and checkpoint.get("video_fps"):
        checkpoint = {"elapsed_s": round(checkpoint["elapsed_ms"] / 1000, 2),
                      "video_s": round((checkpoint["frame"] + 1) / checkpoint["video_fps"], 2)}
    else:
        checkpoint = None
    return {"frames_received": len(received), "checkpoint_45s": checkpoint,
            "round_trip_ms": stats(values("received", "round_trip_ms")),
            "server_read_ms": stats(server_stages["read"]),
            "server_jpeg_encode_ms": stats(server_stages["jpeg"]),
            "server_processing_ms": stats(server_stages["processing"]),
            "pacing_below_frame_interval": {"count": paced_below_interval,
                                             "frames": len(paced)} if paced else None,
            "ideal_read_overlap_cycle_reduction_pct":
                round(100 * overlap_ms / cycle_ms, 2) if cycle_ms else None,
            "json_ms": stats(values("received", "json_ms")),
            "handling_ms": stats(values("received", "handle_ms")),
            "next_request_delay_ms": stats(values("next", "since_response_ms")),
            "ui_callback_delay_ms": stats(values("ui_frame", "since_response_ms")),
            "image_ready_since_response_ms": stats(values("image_ready", "since_response_ms")),
            "jpeg_codec_sample_ms": stats(values("jpeg_codec_sample", "decode_ms")),
            "image_stream_decode_ms": stats(values("image_stream_decode", "decode_ms")),
            "frame_build_ms": stats(values("frame_timing", "build_ms")),
            "frame_raster_ms": stats(values("frame_timing", "raster_ms")),
            "server_serialize_ms": stats([row["serialize_ms"] for row in transports
                                          if isinstance(row.get("serialize_ms"), (int, float))]),
            "server_send_await_ms": stats([row["send_await_ms"] for row in transports
                                           if isinstance(row.get("send_await_ms"), (int, float))]),
            "serialize_start_to_client_receive_ms_same_host": stats(delivery),
            "analysis_saved_ms": values("analysis_saved", "elapsed_ms"),
            "clock_stopped_ms": values("clock_stopped", "elapsed_ms"),
            "stop_status": [row.get("status") for row in rows
                            if row.get("event") == "clock_stopped"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--same-host", action="store_true",
                        help="server and Flutter use the same machine wall clock")
    args = parser.parse_args()
    sessions, current = [], None
    data = args.log.read_bytes()
    # Windows PowerShell 5.1 Tee-Object writes UTF-16LE with a BOM by default.
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    for line in data.decode(encoding, errors="replace").splitlines():
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
    print(json.dumps([summarize(session, same_host=args.same_host) for session in sessions], indent=2))


if __name__ == "__main__":
    main()
