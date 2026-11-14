"""Doubles evaluation against labelled team clips (T9.12).

Usage: python scripts/eval_doubles.py --pred out/record.json --gt labels/doubles01.csv
                [--boxes labels/doubles01_boxes.csv] [--pred ... --gt ... --boxes ...]
                [--tolerance 3] [--rally-tolerance 1.0] [--max-step-m 1.5] [--min-iou 0.5]
                [--out ../docs/results/doubles.md]

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
  position moves more than --max-step-m meters from the previous frame;
- with --boxes (label_clip.py --boxes, one file per --pred, all or none): ID switches (a
  labelled player matched to a different tracked slot than at their previous labelled
  frame, IoU >= --min-iou), per labelled rally, and IDF1 under the best fixed assignment of
  labelled players to tracked slots. Boxes are in source pixels, like the record's.
No number is promised before it is measured on real labels.
"""

from __future__ import annotations

import argparse
import csv
import json
from itertools import permutations
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


Box = tuple[float, float, float, float]


def read_boxes(path: Path) -> dict[int, dict[str, Box]]:
    """Labelled player boxes {frame: {slot: (x, y, w, h)}}; slots not in view are left out."""
    boxes: dict[int, dict[str, Box]] = {}
    for row in _rows(path):
        slot = _slot(row.get("slot"))
        if slot is None or not row.get("frame"):
            continue
        frame = boxes.setdefault(int(row["frame"]), {})
        if row.get("w") and row.get("h"):
            frame[slot] = tuple(float(row[k]) for k in ("x", "y", "w", "h"))  # type: ignore[assignment]
    return boxes


def iou(a: Box, b: Box) -> float:
    ax2, ay2, bx2, by2 = a[0] + a[2], a[1] + a[3], b[0] + b[2], b[1] + b[3]
    w = max(0.0, min(ax2, bx2) - max(a[0], b[0]))
    h = max(0.0, min(ay2, by2) - max(a[1], b[1]))
    inter = w * h
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


def _tracked(record: ClipRecord, frame: int) -> dict[str, Box]:
    if not 0 <= frame < len(record.frames) or record.frames[frame].players is None:
        return {}
    players = record.frames[frame].players
    out = {}
    for slot in PLAYER_IDS:
        p = getattr(players, slot_attr(slot), None)
        if p is not None:
            out[slot] = tuple(p.bbox)
    return out  # type: ignore[return-value]


def identity_metrics(
    record: ClipRecord,
    boxes: dict[int, dict[str, Box]],
    rallies: list[dict[str, Any]],
    min_iou: float = 0.5,
) -> dict[str, Any]:
    """ID switches (per labelled rally) and IDF1 against labelled player boxes (T9.12)."""
    fps = record.fps or 30.0
    frames = sorted(boxes)
    # Per frame, each labelled player's tracked slot: greedy by IoU, one slot per player.
    matched: dict[str, list[tuple[int, str]]] = {slot: [] for slot in PLAYER_IDS}
    for f in frames:
        tracked = _tracked(record, f)
        pairs = sorted(((iou(g, t), gs, ts) for gs, g in boxes[f].items()
                        for ts, t in tracked.items()), reverse=True)  # fmt: skip
        used_g, used_t = set(), set()
        for score, gs, ts in pairs:
            if score < min_iou or gs in used_g or ts in used_t:
                continue
            used_g.add(gs)
            used_t.add(ts)
            matched[gs].append((f, ts))
    switches = []
    for track in matched.values():
        switches += [f for (_, a), (f, b) in zip(track, track[1:], strict=False) if a != b]
    in_rally = [
        f for f in switches
        if any(r["start_s"] * fps <= f <= r["end_s"] * fps for r in rallies)
    ]  # fmt: skip
    # IDF1: the fixed labelled-player -> tracked-slot assignment with the most true matches.
    gt_total = sum(len(b) for b in boxes.values())
    pred_total = sum(len(_tracked(record, f)) for f in frames)
    best = 0
    for perm in permutations(PLAYER_IDS):
        assign = dict(zip(PLAYER_IDS, perm, strict=True))
        tp = 0
        for f in frames:
            tracked = _tracked(record, f)
            for gs, g in boxes[f].items():
                t = tracked.get(assign[gs])
                tp += t is not None and iou(g, t) >= min_iou
        best = max(best, tp)
    denom = 2 * best + (pred_total - best) + (gt_total - best)
    return {
        "box_frames": len(frames),
        "labelled_boxes": gt_total,
        "id_switches": len(switches),
        "id_switches_per_rally": len(in_rally) / len(rallies) if rallies else None,
        "idf1": 2 * best / denom if denom else None,
    }


def evaluate(
    record: ClipRecord, gt: Path, args: argparse.Namespace, boxes: Path | None = None
) -> dict[str, Any]:
    labels = read_labels(gt, record.fps or 30.0)
    result = {
        "clip": record.clip_id,
        **hitter_metrics(record, labels["hits"], args.tolerance),
        **service_metrics(record, labels["rallies"], args.rally_tolerance),
        **slot_jumps(record, args.max_step_m),
        "box_frames": 0, "labelled_boxes": 0, "id_switches": None,
        "id_switches_per_rally": None, "idf1": None,
    }  # fmt: skip
    if boxes is not None:
        min_iou = getattr(args, "min_iou", 0.5)
        result |= identity_metrics(record, read_boxes(boxes), labels["rallies"], min_iou)
    return result


def _fmt(value: Any) -> str:
    return "—" if value is None else f"{value:.1%}" if isinstance(value, float) else str(value)


def markdown(results: list[dict[str, Any]]) -> str:
    cols = ["clip", "matched_hits", "hitter_accuracy", "hitter_unknown_rate", "matched_rallies",
            "service_accuracy", "slot_jumps", "slot_steps", "box_frames", "id_switches",
            "id_switches_per_rally", "idf1"]  # fmt: skip
    lines = [
        "# Doubles evaluation (T9.12)",
        "",
        "Generated by `scripts/eval_doubles.py`. Slot jumps are a label-free proxy for "
        "identity switches; ID switches and IDF1 come from labelled player boxes "
        "(`label_clip.py --boxes`) and are empty without them.",
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
    parser.add_argument("--boxes", type=Path, action="append", default=None)
    parser.add_argument("--min-iou", type=float, default=0.5)
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "doubles.md")
    args = parser.parse_args()
    if len(args.pred) != len(args.gt):
        parser.error("give one --gt per --pred")
    if args.boxes is not None and len(args.boxes) != len(args.pred):
        parser.error("give one --boxes per --pred, or none")
    boxes = args.boxes or [None] * len(args.pred)
    results = [
        evaluate(load_record(p.read_text(encoding="utf-8")), gt, args, b)
        for p, gt, b in zip(args.pred, args.gt, boxes, strict=True)
    ]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(markdown(results), encoding="utf-8")
    args.out.with_suffix(".json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    print(markdown(results))


if __name__ == "__main__":
    main()
