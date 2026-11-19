"""Summarize Watch CUDA activity, attributed approximately by launch correlation."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", required=True, type=Path)
    parser.add_argument("--ranges", required=True, type=Path)
    parser.add_argument("--anchor", default="watch_clock_anchor")
    args = parser.parse_args()
    events = json.loads(args.trace.read_text(encoding="utf8"))["traceEvents"]
    data = json.loads(args.ranges.read_text(encoding="utf8"))
    anchors = [e for e in events if e.get("name") == args.anchor and e.get("ph") == "X"]
    if len(anchors) != 1:
        raise ValueError(f"expected one trace clock anchor, got {len(anchors)}")
    by_thread = defaultdict(list)
    for item in data["ranges"]:
        start = anchors[0]["ts"] + (item["start_ns"] - data["anchor_ns"]) / 1000
        end = anchors[0]["ts"] + (item["end_ns"] - data["anchor_ns"]) / 1000
        by_thread[item["tid"]].append((start, end, item["name"]))
    owners = {}
    syncs = defaultdict(lambda: [0, 0.0])
    for event in events:
        if event.get("cat") != "cuda_runtime":
            continue
        matching = [r for r in by_thread.get(event.get("tid"), ()) if r[0] <= event["ts"] <= r[1]]
        if matching:
            owner = min(matching, key=lambda r: r[1] - r[0])[2]
            correlation = event.get("args", {}).get("correlation")
            if correlation is not None:
                owners[correlation] = owner
            if "Synchronize" in event.get("name", ""):
                syncs[owner][0] += 1
                syncs[owner][1] += event.get("dur", 0)
    activities = defaultdict(lambda: defaultdict(lambda: [0, 0.0]))
    for event in events:
        category = event.get("cat")
        if category not in ("kernel", "gpu_memcpy", "gpu_memset"):
            continue
        owner = owners.get(event.get("args", {}).get("correlation"), "unattributed")
        key = event.get("name", category) if category == "gpu_memcpy" else category
        values = activities[owner][key]
        values[0] += 1
        values[1] += event.get("dur", 0)
    print(
        json.dumps(
            {"activities_count_total_us": activities, "sync_count_total_us": syncs}, indent=2
        )
    )


if __name__ == "__main__":
    main()
