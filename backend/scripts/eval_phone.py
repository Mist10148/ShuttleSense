"""Evaluation on the team's phone footage (T7.2).

Usage: python scripts/eval_phone.py --record out/rally01/record.json --gt labels/rally01.csv
                [--record ... --gt ...] [--tolerance-s 0.1] [--rally-tolerance 1.0]
                [--out ../docs/results/phone.md]

--record is a record.json from the frozen pipeline (run with calibration, and the referee
stage for rally boundaries); pair each with its T7.1 label file (scripts/label_clip.py).

Label file (UTF-8, header row), one row per labelled event:
    hit rows    time_s, player (near | far), stroke (smash, clear, drop, net_shot, lift, serve)
    rally rows  start_s, end_s, winner (near | far | empty), in_out (optional)

Reported per clip and pooled:
- hit detection P/R/F1, a predicted hit matching a label within +-tolerance (0.1 s is
  +-3 frames at 30 fps), and player accuracy on matched hits;
- stroke accuracy on matched hits whose label has a stroke (target >= 55%), plus a
  confusion table;
- stroke count error per labelled rally: |predicted hits - labelled hits| inside the rally
  window (target mean <= 1);
- rally boundary accuracy against the record's rallies (target >= 80%).
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path
from typing import Any

from shuttlesense.config import BACKEND_DIR
from shuttlesense.evaluation import hit_metrics, match_events, rally_boundary_accuracy
from shuttlesense.schema import STROKE_CLASSES, ClipRecord, load_record

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"
SIDES = ("near", "far")


def _rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as f:
        return [{k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
                for row in csv.DictReader(f)]  # fmt: skip


def read_labels(path: Path) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(hits, rallies) from a T7.1 label file, each in time order."""
    hits, rallies = [], []
    for r in _rows(path):
        if r.get("time_s"):
            player = r.get("player", "").lower()
            stroke = r.get("stroke", "").lower()
            hits.append({
                "time_s": float(r["time_s"]),
                "player": player if player in SIDES else "",
                "stroke": stroke if stroke in STROKE_CLASSES else None,
            })  # fmt: skip
        elif r.get("start_s") and r.get("end_s"):
            winner = r.get("winner", "").lower()
            rallies.append({
                "start_s": float(r["start_s"]),
                "end_s": float(r["end_s"]),
                "winner": winner if winner in SIDES else None,
            })  # fmt: skip
    return sorted(hits, key=lambda h: h["time_s"]), sorted(rallies, key=lambda r: r["start_s"])


def evaluate_clip(
    record: ClipRecord,
    hits_true: list[dict[str, Any]],
    rallies_true: list[dict[str, Any]],
    tolerance_s: float = 0.1,
    rally_tolerance_s: float = 1.0,
) -> dict[str, Any]:
    fps = record.fps or 30.0
    tolerance = max(1, round(tolerance_s * fps))
    pred = [(h.frame, h.player) for h in record.hits]
    truth = [(round(h["time_s"] * fps), h["player"]) for h in hits_true]
    hits = hit_metrics(pred, truth, tolerance)

    confusion: Counter = Counter()
    for i, j in match_events([p[0] for p in pred], [t[0] for t in truth], tolerance):
        label = hits_true[j]["stroke"]
        if label is not None:
            confusion[(label, record.hits[i].stroke or "none")] += 1
    judged = sum(confusion.values())
    correct = sum(n for (label, guess), n in confusion.items() if label == guess)

    count_errors = []
    for r in rallies_true:
        n_true = sum(1 for h in hits_true if r["start_s"] <= h["time_s"] <= r["end_s"])
        n_pred = sum(1 for h in record.hits if r["start_s"] <= h.frame / fps <= r["end_s"])
        count_errors.append(abs(n_pred - n_true))

    boundary = rally_boundary_accuracy(
        [(r.start_frame / fps, r.end_frame / fps) for r in record.rallies],
        [(r["start_s"], r["end_s"]) for r in rallies_true],
        rally_tolerance_s,
    )
    return {
        "tolerance_frames": tolerance,
        "hits": {"predicted": len(pred), "truth": len(truth), **hits},
        "stroke": {
            "judged": judged,
            "correct": correct,
            "accuracy": correct / judged if judged else None,
            "confusion": {
                f"{label}->{guess}": n for (label, guess), n in sorted(confusion.items())
            },
        },
        "count_error": {
            "rallies": len(count_errors),
            "per_rally": count_errors,
            "mean": sum(count_errors) / len(count_errors) if count_errors else None,
            "max": max(count_errors) if count_errors else None,
        },
        "rallies": {
            "truth": len(rallies_true),
            "predicted": len(record.rallies),
            "boundary_accuracy": boundary if rallies_true else None,
        },
    }


def pooled(results: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Totals over all clips (sums of counts, not means of per-clip rates)."""

    def total(path: tuple[str, str]) -> int:
        return sum(r[path[0]][path[1]] for r in results.values())

    predicted, truth, matched = (total(("hits", k)) for k in ("predicted", "truth", "matched"))
    precision = matched / predicted if predicted else 0.0
    recall = matched / truth if truth else 0.0
    judged, correct = total(("stroke", "judged")), total(("stroke", "correct"))
    errors = [e for r in results.values() for e in r["count_error"]["per_rally"]]
    rallies_true = total(("rallies", "truth"))
    rallies_ok = sum(
        round((r["rallies"]["boundary_accuracy"] or 0.0) * r["rallies"]["truth"])
        for r in results.values()
    )
    return {
        "hits": {
            "predicted": predicted,
            "truth": truth,
            "matched": matched,
            "precision": precision,
            "recall": recall,
            "f1": 2 * precision * recall / (precision + recall) if precision + recall else 0.0,
        },
        "stroke_accuracy": correct / judged if judged else None,
        "count_error_mean": sum(errors) / len(errors) if errors else None,
        "boundary_accuracy": rallies_ok / rallies_true if rallies_true else None,
    }


def _pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.1%}"


def _num(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f}"


def to_markdown(results: dict[str, dict[str, Any]], overall: dict[str, Any]) -> str:
    lines = [
        "# Phone footage evaluation",
        "",
        "Targets: stroke accuracy >= 55%, stroke count error <= 1 per rally, rally boundary "
        "accuracy >= 80%.",
        "",
        "| Clip | Hits (pred / true) | Hit F1 | Stroke acc. | Count error (mean / max) | "
        "Rally boundaries |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name, r in results.items():
        h, ce = r["hits"], r["count_error"]
        lines.append(
            f"| {name} | {h['predicted']} / {h['truth']} | {h['f1']:.3f} | "
            f"{_pct(r['stroke']['accuracy'])} | {_num(ce['mean'])} / {ce['max'] or 0} | "
            f"{_pct(r['rallies']['boundary_accuracy'])} |"
        )
    h = overall["hits"]
    lines += [
        f"| **all** | {h['predicted']} / {h['truth']} | **{h['f1']:.3f}** | "
        f"**{_pct(overall['stroke_accuracy'])}** | **{_num(overall['count_error_mean'])}** | "
        f"**{_pct(overall['boundary_accuracy'])}** |",
        "",
        "## Stroke confusion (label -> predicted, matched hits)",
        "",
        "| Clip | Pairs |",
        "| --- | --- |",
    ]
    for name, r in results.items():
        pairs = ", ".join(f"{k}: {n}" for k, n in r["stroke"]["confusion"].items()) or "-"
        lines.append(f"| {name} | {pairs} |")
    lines.append("")
    return "\n".join(lines)


def write_report(data: dict[str, Any], markdown: str, out_md: Path) -> None:
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(markdown, encoding="utf-8")
    out_md.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", type=Path, action="append", required=True)
    parser.add_argument("--gt", type=Path, action="append", required=True)
    parser.add_argument("--tolerance-s", type=float, default=0.1, help="hit matching window")
    parser.add_argument("--rally-tolerance", type=float, default=1.0, help="seconds")
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "phone.md")
    args = parser.parse_args()
    if len(args.record) != len(args.gt):
        raise SystemExit("give one --gt per --record")

    results = {}
    for rec_path, gt in zip(args.record, args.gt, strict=True):
        record = load_record(rec_path.read_text(encoding="utf-8"))
        hits, rallies = read_labels(gt)
        results[gt.stem] = evaluate_clip(
            record, hits, rallies, args.tolerance_s, args.rally_tolerance
        )
    overall = pooled(results)
    markdown = to_markdown(results, overall)
    print(markdown)
    data = {"tolerance_s": args.tolerance_s, "overall": overall, "clips": results}
    write_report(data, markdown, args.out)
    print(f"wrote {args.out} and {args.out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
