"""Summarize approximate Watch CPU ranges and traced GPU kernel timeline.

GPU attribution is by same-thread runtime correlation; missing launches, other
processes, graph activity and profiler overhead limit interpretation.
"""

from __future__ import annotations

import argparse
import bisect
import json
from collections import defaultdict
from pathlib import Path


def merge(intervals):
    result = []
    for start, end in sorted(intervals):
        if end <= start:
            continue
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(end, result[-1][1]))
        else:
            result.append((start, end))
    return result


def intersect(left, right):
    a, b = merge(left), merge(right)
    result = []
    i = j = 0
    while i < len(a) and j < len(b):
        start, end = max(a[i][0], b[j][0]), min(a[i][1], b[j][1])
        if start < end:
            result.append((start, end))
        if a[i][1] <= b[j][1]:
            i += 1
        else:
            j += 1
    return result


def duration(intervals):
    return sum(end - start for start, end in merge(intervals))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--ranges", type=Path, required=True)
    parser.add_argument("--anchor", default="watch_clock_anchor")
    parser.add_argument("--skip-frames", type=int, default=1)
    args = parser.parse_args()
    events = json.loads(args.trace.read_text(encoding="utf8"))["traceEvents"]
    data = json.loads(args.ranges.read_text(encoding="utf8"))
    anchors = [e for e in events if e.get("name") == args.anchor and e.get("ph") == "X"]
    if len(anchors) != 1 or args.skip_frames < 0:
        raise ValueError("expected exactly one anchor and nonnegative skip-frames")
    by_thread = defaultdict(list)
    paths = defaultdict(list)
    for item in data["ranges"]:
        start = anchors[0]["ts"] + (item["start_ns"] - data["anchor_ns"]) / 1000
        end = anchors[0]["ts"] + (item["end_ns"] - data["anchor_ns"]) / 1000
        by_thread[item["tid"]].append((start, end, item["name"]))
        paths[item["name"]].append((start, end))
    shuttle = sorted(paths["shuttle"])
    players = sorted(paths["players"])
    if len(shuttle) != len(players) or args.skip_frames >= len(shuttle):
        raise ValueError("expected matching nonempty per-frame shuttle/player ranges")
    shuttle, players = shuttle[args.skip_frames:], players[args.skip_frames:]
    windows = merge([(min(s[0], p[0]), max(s[1], p[1]))
                     for s, p in zip(shuttle, players, strict=True)])
    owner_by_correlation = {}
    for event in events:
        if event.get("cat") != "cuda_runtime":
            continue
        matches = [r for r in by_thread.get(event.get("tid"), ())
                   if r[0] <= event["ts"] <= r[1]]
        correlation = event.get("args", {}).get("correlation")
        if matches and correlation is not None:
            owner_by_correlation[correlation] = min(matches, key=lambda r: r[1] - r[0])[2]
    # Restrict kernels to captured frame ranges. The clip does not show other processes.
    kernels = defaultdict(list)
    starts = [start for start, _ in windows]
    for event in events:
        if event.get("cat") != "kernel" or event.get("args", {}).get("device") != 0:
            continue
        start, end = event["ts"], event["ts"] + event.get("dur", 0)
        index = max(0, bisect.bisect_right(starts, start) - 1)
        while index < len(windows) and windows[index][0] < end:
            left, right = max(start, windows[index][0]), min(end, windows[index][1])
            if left < right:
                owner = owner_by_correlation.get(event.get("args", {}).get("correlation"),
                                                 "unattributed")
                kernels[owner].append((left, right))
            index += 1
    all_kernels = merge([interval for group in kernels.values() for interval in group])
    player_kernels = kernels["detector"] + kernels["pose"] + kernels["players"]
    gaps = []
    for start, end in windows:
        cursor = start
        for left, right in intersect(all_kernels, [(start, end)]):
            if left > cursor:
                gaps.append(left - cursor)
            cursor = max(cursor, right)
        if cursor < end:
            gaps.append(end - cursor)
    gaps.sort()
    print(json.dumps({
        "frames": len(shuttle), "skipped_frames": args.skip_frames,
        "frame_window_ms": duration(windows) / 1000,
        "cpu_path_overlap_ms": duration(intersect(shuttle, players)) / 1000,
        "gpu_kernel_union_ms": duration(all_kernels) / 1000,
        "gpu_shuttle_player_overlap_ms": (
            duration(intersect(kernels["shuttle"], player_kernels)) / 1000
        ),
        "gpu_unattributed_kernel_union_ms": duration(kernels["unattributed"]) / 1000,
        "observed_kernel_gaps": {"count": len(gaps), "over_1ms": sum(x > 1000 for x in gaps),
                                 "total_ms": sum(gaps) / 1000,
                                 "max_ms": max(gaps, default=0) / 1000},
    }, indent=2))


if __name__ == "__main__":
    main()
