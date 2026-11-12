"""Doubles evaluation against labelled team clips (T9.12).

Usage: python scripts/eval_doubles.py --pred out/record.json --gt labels/doubles01.csv
                [--pred ... --gt ...] [--tolerance 3] [--rally-tolerance 1.0]
                [--max-step-m 1.5] [--out ../docs/results/doubles.md]

--pred is a pipeline record.json of a doubles job (court: doubles); pair each with one --gt,
the label file written by label_clip.py in doubles mode:
    hit rows     time_s, player (a slot: near_1, near_2, far_1, far_2)
    rally rows   start_s, end_s, server, receiver (slots, filled by label_clip.py)

Reported, with the sample size next to every number:
- hitter accuracy: on labelled hits matched to a detected hit (+-tolerance frames, same
  side), how often Hit.hitter names the labelled partner; and how often it is left unknown;
- service order: on labelled rallies matched to a detected rally (start and end within
  +-rally-tolerance seconds), how often Rally.server_id and receiver_id match the labels;
- slot jumps: a label-free proxy for identity switches, counting frames where a slot's court
  position moves more than --max-step-m meters from the previous frame. True ID switches need
  per-frame box labels (T9.2) and are not computed here.
No number is promised before it is measured on real labels.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from shuttlesense.config import BACKEND_DIR
from shuttlesense.evaluation import match_events
from shuttlesense.schema import PLAYER_IDS, ClipRecord, load_record, slot_attr

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"


def _rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as f:
        return [{k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
                for row in csv.DictReader(f)]  # fmt: skip


def _slot(value: str | None) -> str | None:
    value = (value or "").lower()
    return value if value in PLAYER_IDS else None


def read_labels(path: Path, fps: float) -> dict[str, list[dict[str, Any]]]:
    """Labelled hits {frame, slot} and rallies {start_s, end_s, server, receiver}."""
    hits, rallies = [], []
    for row in _rows(path):
        if row.get("time_s"):
            hits.append({"frame": round(float(row["time_s"]) * fps), "slot": _slot(row["player"])})
        elif row.get("start_s") and row.get("end_s"):
            rallies.append({
                "start_s": float(row["start_s"]), "end_s": float(row["end_s"]),
                "server": _slot(row.get("server")), "receiver": _slot(row.get("receiver")),
            })  # fmt: skip
    return {"hits": sorted(hits, key=lambda h: h["frame"]), "rallies": rallies}


def hitter_metrics(record: ClipRecord, labels: list[dict], tolerance: int) -> dict[str, Any]:
    truth = [h for h in labels if h["slot"]]
    matched = match_events([h.frame for h in record.hits], [h["frame"] for h in truth], tolerance)
    pairs = [
        (record.hits[i], truth[j])
        for i, j in matched
        if record.hits[i].player == truth[j]["slot"].split("_")[0]  # same side
    ]
    named = [(h, t) for h, t in pairs if h.hitter is not None]
    correct = sum(1 for h, t in named if h.hitter == t["slot"])
    return {
        "labelled_hits": len(truth),
        "matched_hits": len(pairs),
        "hitter_named": len(named),
        "hitter_accuracy": correct / len(named) if named else None,
        "hitter_unknown_rate": 1 - len(named) / len(pairs) if pairs else None,
    }


def service_metrics(record: ClipRecord, labels: list[dict], tolerance_s: float) -> dict[str, Any]:
    fps = record.fps or 30.0
    truth = [r for r in labels if r["server"] and r["receiver"]]
    pred = [(r.start_frame / fps, r.end_frame / fps) for r in record.rallies]
    # Same greedy matching as evaluation.rally_boundary_accuracy, keeping the pairs.
    pairs, used = [], set()
    for j, t in enumerate(truth):
        for i, (ps, pe) in enumerate(pred):
            near_start = abs(ps - t["start_s"]) <= tolerance_s
            if i not in used and near_start and abs(pe - t["end_s"]) <= tolerance_s:
                used.add(i)
                pairs.append((i, j))
                break
    both = sum(
        1
        for i, j in pairs
        if record.rallies[i].server_id == truth[j]["server"]
        and record.rallies[i].receiver_id == truth[j]["receiver"]
    )
    return {
        "labelled_rallies": len(truth),
        "matched_rallies": len(pairs),
        "service_accuracy": both / len(pairs) if pairs else None,
    }


def slot_jumps(record: ClipRecord, max_step_m: float) -> dict[str, Any]:
    """Frames where a slot's court position jumps more than max_step_m (identity proxy)."""
    jumps, steps = 0, 0
    for slot in PLAYER_IDS:
        prev = None
        for f in record.frames:
            pos = getattr(f.court_positions, slot_attr(slot), None) if f.court_positions else None
            if pos is not None and prev is not None:
                steps += 1
                jumps += ((pos[0] - prev[0]) ** 2 + (pos[1] - prev[1]) ** 2) ** 0.5 > max_step_m
            prev = pos
    return {"slot_steps": steps, "slot_jumps": jumps}


def evaluate(record: ClipRecord, gt: Path, args: argparse.Namespace) -> dict[str, Any]:
    labels = read_labels(gt, record.fps or 30.0)
    return {
        "clip": record.clip_id,
        **hitter_metrics(record, labels["hits"], args.tolerance),
        **service_metrics(record, labels["rallies"], args.rally_tolerance),
        **slot_jumps(record, args.max_step_m),
    }


def _fmt(value: Any) -> str:
    return "—" if value is None else f"{value:.1%}" if isinstance(value, float) else str(value)


def markdown(results: list[dict[str, Any]]) -> str:
    cols = ["clip", "matched_hits", "hitter_accuracy", "hitter_unknown_rate", "matched_rallies",
            "service_accuracy", "slot_jumps", "slot_steps"]  # fmt: skip
    lines = [
        "# Doubles evaluation (T9.12)",
        "",
        "Generated by `scripts/eval_doubles.py`. Slot jumps are a label-free proxy for "
        "identity switches, not a measured ID-switch rate.",
        "",
        "| " + " | ".join(cols) + " |",
        "| " + " | ".join("---" for _ in cols) + " |",
    ]
    lines += ["| " + " | ".join(_fmt(r[c]) for c in cols) + " |" for r in results]
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pred", type=Path, action="append", required=True)
    parser.add_argument("--gt", type=Path, action="append", required=True)
    parser.add_argument("--tolerance", type=int, default=3)
    parser.add_argument("--rally-tolerance", type=float, default=1.0)
    parser.add_argument("--max-step-m", type=float, default=1.5)
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "doubles.md")
    args = parser.parse_args()
    if len(args.pred) != len(args.gt):
        parser.error("give one --gt per --pred")
    results = [
        evaluate(load_record(p.read_text(encoding="utf-8")), gt, args)
        for p, gt in zip(args.pred, args.gt, strict=True)
    ]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(markdown(results), encoding="utf-8")
    args.out.with_suffix(".json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(markdown(results))


if __name__ == "__main__":
    main()
