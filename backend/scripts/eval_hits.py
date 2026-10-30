"""Hit detection evaluation and threshold grid search (T3.7).

Usage: python scripts/eval_hits.py --record out/record.json --gt labels.csv
                [--record ... --gt ...] [--tolerance 3] [--redetect] [--gt-step 1]
                [--gt-offset 0]
                [--grid --angles 45,60,75 --wrist 80,120,160 --gaps 6,8,10 --tag val]
                [--out ../docs/results/hits.md] [--tuning-log ../docs/results/hits_tuning.csv]

--record is a pipeline record.json (run with tracking + pose); pair each with one --gt in
the same order. Predicted hits are record.hits, or with --redetect they are recomputed by
hits.detect_hits from the record's shuttle track and wrists using configs/pipeline.yaml.

Ground-truth CSV (one per clip, UTF-8, header row), columns:
    frame | time_s | frame_num   hit frame in normalized frames, or seconds (x record fps),
                                 or a ShuttleSet source frame: frame_num counts from the
                                 start of the full match video, so --gt-offset (the source
                                 frame where the clip starts) is subtracted, then the result
                                 is divided by --gt-step
    player                       near | far (anything else, e.g. ShuttleSet A/B, counts as
                                 unknown and is left out of player accuracy)
    stroke                       optional, ignored here
Rows without a frame/time are skipped, so a T7.1 labels/<clip>.csv that also holds rally rows
(start_s,end_s,...) can be passed as is. Labels outside the record's frames are dropped, so a
whole-set ShuttleSet CSV can be scored against a 5-minute clip of it.

Matching is greedy one-to-one within +-tolerance frames (shuttlesense.evaluation); precision,
recall and F1 are pooled over all clips. --grid evaluates every threshold combination (run it
on the val matches only), appends each one to the tuning log and prints the best by F1; copy
those values to configs/pipeline.yaml by hand.
"""

from __future__ import annotations

import argparse
import csv
import itertools
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from shuttlesense.config import BACKEND_DIR, load_config
from shuttlesense.evaluation import hit_metrics
from shuttlesense.schema import ClipRecord
from shuttlesense.schema import load_record as parse_record

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"
SIDES = ("near", "far")
TUNING_COLUMNS = (
    "timestamp",
    "tag",
    "min_angle_deg",
    "max_wrist_distance_px",
    "min_frames_between_hits",
    "tolerance",
    "clips",
    "predicted",
    "truth",
    "matched",
    "precision",
    "recall",
    "f1",
    "player_accuracy",
)

Event = tuple[int, str]


def load_record(path: Path) -> ClipRecord:
    return parse_record(path.read_text(encoding="utf-8"))


def read_hit_labels(path: Path, fps: float, step: int = 1, offset: int = 0) -> list[Event]:
    """(frame, player) per labelled hit, in frame order.

    ShuttleSet frame_num values have `offset` subtracted and are divided by `step`."""
    hits: list[Event] = []
    with path.open(newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            row = {k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
            if row.get("frame"):
                frame = int(float(row["frame"]))
            elif row.get("time_s"):
                frame = round(float(row["time_s"]) * fps)
            elif row.get("frame_num"):
                frame = round((int(float(row["frame_num"])) - offset) / step)
            else:
                continue
            player = row.get("player", "").lower()
            hits.append((frame, player if player in SIDES else ""))
    return sorted(hits)


def in_record(record: ClipRecord, events: list[Event]) -> list[Event]:
    """Events whose frame lies within the record (0 <= frame < num_frames)."""
    n = record.num_frames or len(record.frames)
    return [e for e in events if 0 <= e[0] < n]


def recorded_hits(record: ClipRecord) -> list[Event]:
    return [(h.frame, h.player) for h in record.hits]


def redetect(record: ClipRecord, cfg: dict[str, Any]) -> list[Event]:
    """detect_hits on the record's track and wrists, as the hits stage does."""
    import numpy as np

    from shuttlesense.hits.detector import detect_hits, wrist_arrays
    from shuttlesense.tracking import track_arrays

    cfg = {**cfg, "scale": (record.height or 720) / 720}
    xy, visible = track_arrays(record)
    return detect_hits(
        np.nan_to_num(xy), visible, wrist_arrays(record, "near"), wrist_arrays(record, "far"), cfg
    )


def pooled_metrics(pairs: list[tuple[list[Event], list[Event]]], tolerance: int) -> dict:
    """Precision/recall/F1 over all clips; player accuracy on matched hits with a known GT
    player (None if there are none)."""
    n_pred = n_true = matched = same = known = 0
    per_clip = []
    for pred, truth in pairs:
        m = {**hit_metrics(pred, truth, tolerance), "predicted": len(pred), "truth": len(truth)}
        per_clip.append(m)
        n_pred += len(pred)
        n_true += len(truth)
        matched += int(m["matched"])
        labelled = [t for t in truth if t[1]]
        if labelled:
            k = hit_metrics(pred, labelled, tolerance)
            known += int(k["matched"])
            same += round(k["player_accuracy"] * k["matched"])
    precision = matched / n_pred if n_pred else 0.0
    recall = matched / n_true if n_true else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {
        "clips": len(pairs),
        "predicted": n_pred,
        "truth": n_true,
        "matched": matched,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "player_accuracy": same / known if known else None,
        "per_clip": per_clip,
    }


def grid_search(
    clips: list[tuple[ClipRecord, list[Event]]],
    base_cfg: dict[str, Any],
    grid: dict[str, list[float]],
    tolerance: int,
) -> list[dict[str, Any]]:
    """One row per threshold combination, best F1 first."""
    rows = []
    keys = list(grid)
    for values in itertools.product(*(grid[k] for k in keys)):
        cfg = {**base_cfg, **dict(zip(keys, values, strict=True))}
        pairs = [(redetect(record, cfg), truth) for record, truth in clips]
        m = pooled_metrics(pairs, tolerance)
        m.pop("per_clip")
        rows.append({**dict(zip(keys, values, strict=True)), "tolerance": tolerance, **m})
    rows.sort(key=lambda r: -r["f1"])
    return rows


def append_tuning_log(path: Path, rows: list[dict[str, Any]], tag: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    stamp = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    with path.open("a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, TUNING_COLUMNS, extrasaction="ignore")
        if new:
            writer.writeheader()
        for row in rows:
            writer.writerow({**row, "timestamp": stamp, "tag": tag})


def _fmt(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.3f}"


def to_markdown(result: dict[str, Any], names: list[str], tolerance: int) -> str:
    lines = [
        "# Hit detection",
        "",
        f"Greedy one-to-one matching within +-{tolerance} frames.",
        "",
        "| Clip | Predicted | Truth | Matched | Precision | Recall | F1 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name, m in zip(names, result["per_clip"], strict=True):
        lines.append(
            f"| {name} | {m['predicted']} | {m['truth']} | {int(m['matched'])} | "
            f"{m['precision']:.3f} | "
            f"{m['recall']:.3f} | {m['f1']:.3f} |"
        )
    lines += [
        f"| **all** | {result['predicted']} | {result['truth']} | {result['matched']} | "
        f"**{result['precision']:.3f}** | **{result['recall']:.3f}** | **{result['f1']:.3f}** |",
        "",
        f"Player-assignment accuracy on matched hits: {_fmt(result['player_accuracy'])}.",
        "",
    ]
    return "\n".join(lines)


def write_report(data: dict[str, Any], markdown: str, out_md: Path) -> None:
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(markdown, encoding="utf-8")
    out_md.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def _floats(text: str) -> list[float]:
    return [float(v) for v in text.split(",") if v]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", type=Path, action="append", required=True)
    parser.add_argument("--gt", type=Path, action="append", required=True)
    parser.add_argument("--tolerance", type=int, default=3, help="frames")
    parser.add_argument("--gt-step", type=int, default=1, help="source frames per frame")
    parser.add_argument(
        "--gt-offset",
        type=int,
        action="append",
        help="source frame where the clip starts in the match video; once, or once per --gt",
    )
    parser.add_argument("--redetect", action="store_true", help="re-run detect_hits")
    parser.add_argument("--grid", action="store_true", help="grid-search the thresholds")
    parser.add_argument("--angles", type=_floats, default=[45, 60, 75])
    parser.add_argument("--wrist", type=_floats, default=[80, 120, 160])
    parser.add_argument("--gaps", type=_floats, default=[6, 8, 10])
    parser.add_argument("--tag", default="", help="label for the tuning log (e.g. val)")
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "hits.md")
    parser.add_argument("--tuning-log", type=Path, default=RESULTS_DIR / "hits_tuning.csv")
    args = parser.parse_args()
    if len(args.record) != len(args.gt):
        raise SystemExit("give one --gt per --record")

    offsets = args.gt_offset or [0]
    if len(offsets) == 1:
        offsets = offsets * len(args.gt)
    if len(offsets) != len(args.gt):
        raise SystemExit("give --gt-offset once, or once per --gt")
    if args.grid and not (args.angles and args.wrist and args.gaps):
        raise SystemExit("--angles, --wrist and --gaps each need at least one value")

    records = [load_record(p) for p in args.record]
    clips = [(r, in_record(r, read_hit_labels(g, r.fps or 30.0, args.gt_step, off)))
             for r, g, off in zip(records, args.gt, offsets, strict=True)]  # fmt: skip
    base_cfg = dict(load_config().get("stages", {}).get("hits", {}))

    if args.grid:
        grid = {"min_angle_deg": args.angles, "max_wrist_distance_px": args.wrist,
                "min_frames_between_hits": [int(g) for g in args.gaps]}  # fmt: skip
        rows = grid_search(clips, base_cfg, grid, args.tolerance)
        append_tuning_log(args.tuning_log, rows, args.tag)
        best = rows[0]
        print(f"{len(rows)} combinations logged to {args.tuning_log}; best F1 {best['f1']:.3f}:")
        for key in grid:
            print(f"  {key}: {best[key]:g}")
        return

    pairs = [(redetect(r, base_cfg) if args.redetect else recorded_hits(r), truth)
             for r, truth in clips]  # fmt: skip
    result = pooled_metrics(pairs, args.tolerance)
    names = [p.parent.name or p.stem for p in args.record]
    markdown = to_markdown(result, names, args.tolerance)
    print(markdown)
    write_report({"tolerance": args.tolerance, "clips": names, **result}, markdown, args.out)
    print(f"wrote {args.out} and {args.out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
