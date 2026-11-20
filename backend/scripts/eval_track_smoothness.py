"""Shuttle track smoothness of a record.json, without labels (D43).

Usage: python scripts/eval_track_smoothness.py record.json [record2.json ...]
                [--rectify] [--json]

For each record: the share of frames with a visible shuttle, the jitter of the track (mean
squared second difference, px^2 per frame^2, over triples of consecutive visible frames:
a smooth flight scores low, a few pixels of detector noise scores high), the same over
flight segments only (triples that do not straddle a turn the trajectory module found, so
real hits do not count as jitter), the number of hits and of flight segments.

--rectify also runs today's tracking clean-up (tracking.postprocess.rectify, with the
settings in configs/pipeline.yaml) on the record's track and reports the same numbers for
it, so a record made before D43 can be compared with what the new code makes of it. This
needs no model or GPU. It is no accuracy measure: that needs labelled frames
(scripts/eval_tracking.py).
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.schema import ClipRecord, load_record
from shuttlesense.tracking.postprocess import offline_tracking, rectify, track_arrays
from shuttlesense.tracking.trajectory import smooth_points


def jitter(xy: np.ndarray, visible: np.ndarray, skip: set[int] | None = None) -> float | None:
    """Mean squared second difference over consecutive visible triples (centre not in skip)."""
    vis = np.asarray(visible) > 0
    centre = np.flatnonzero(vis[:-2] & vis[1:-1] & vis[2:]) + 1 if len(vis) >= 3 else []
    centre = [int(c) for c in centre if not skip or c not in skip]
    if not centre:
        return None
    c = np.asarray(centre)
    second = xy[c - 1] - 2 * xy[c] + xy[c + 1]
    return float(np.mean(np.sum(second**2, axis=1)))


def track_stats(xy: np.ndarray, visible: np.ndarray, hits: int | None) -> dict[str, Any]:
    vis = np.asarray(visible) > 0
    frames = np.flatnonzero(vis)
    turns: set[int] = set()
    if len(frames) >= 3:
        _, _, turn = smooth_points(frames, xy[frames], reject=False)
        turns = {int(f) for f in frames[turn]}
    j_all, j_flight = jitter(xy, vis), jitter(xy, vis, turns)
    return {
        "frames": int(len(vis)),
        "visible_ratio": round(float(vis.mean()), 4) if len(vis) else 0.0,
        "jitter_px2": None if j_all is None else round(j_all, 3),
        "flight_jitter_px2": None if j_flight is None else round(j_flight, 3),
        "turns": len(turns),
        "hits": hits,
    }


def evaluate(record: ClipRecord, *, rerun: bool = False) -> dict[str, Any]:
    xy, visible = track_arrays(record)
    xy = np.nan_to_num(xy)
    out: dict[str, Any] = {
        "clip_id": record.clip_id,
        "record": track_stats(xy, visible, len(record.hits)),
    }
    if rerun:
        with offline_tracking():  # the upload path, as the tracking stage runs it
            new_xy, new_vis, _ = rectify(
                xy, visible, max_gap=8, outlier_px=80 * (record.height or 720) / 720
            )
        out["rectified"] = track_stats(new_xy, new_vis, None)
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("records", nargs="+", type=Path)
    parser.add_argument("--rectify", action="store_true", help="also run today's clean-up")
    parser.add_argument("--json", action="store_true", help="print JSON instead of a table")
    args = parser.parse_args(argv)
    results = [
        evaluate(load_record(p.read_text(encoding="utf-8")), rerun=args.rectify)
        for p in args.records
    ]
    if args.json:
        print(json.dumps(results, indent=2))
        return 0
    print("| clip | track | visible | jitter px² | flight jitter px² | turns | hits |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for r in results:
        for name in ("record", "rectified"):
            s = r.get(name)
            if s is None:
                continue
            print(
                f"| {r['clip_id']} | {name} | {s['visible_ratio']:.1%} | {s['jitter_px2']} "
                f"| {s['flight_jitter_px2']} | {s['turns']} | {s['hits'] or ''} |"
            )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
