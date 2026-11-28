"""Rally boundary and score evaluation against labelled team clips (T6.7).

Usage: python scripts/eval_rallies.py --pred out/record.json --gt labels/rally01.csv
                [--pred ... --gt ...] [--tolerance 1.0] [--start-score 0-0]
                [--out ../docs/results/rallies.md]

--pred is a pipeline record.json or rallies.csv (run with the referee stage on); pair each
with one --gt in the same order.

Ground truth is the T7.1 label file labels/<clip>.csv (UTF-8, header row). Rally rows have
    start_s, end_s   rally start and end in seconds
    winner           near | far | empty (unknown / let)
    in_out           in | out | empty (optional, not scored here)
Rows without start_s (the hit rows: time_s, player, stroke) are ignored, so the same file
serves eval_hits.py.

A labelled rally is correct when one predicted rally (used once) starts and ends within
+-tolerance seconds of it (shuttlesense.evaluation.rally_boundary_accuracy). On matched
rallies the predicted winner is compared with the label, and the predicted score sequence
(score_after per rally) is compared with the one implied by the labelled winners, scored
from --start-score with referee.apply_rallies.

Each predicted rally from a record.json also says what decided it (D47): its landing, the
next serve, the serve courts (D65), withheld (the landing and the next serve disagree) or
undecided. The report gives the count and winner accuracy per source, so a source that
gives false points shows.

Score error: on matched rallies where both scores are known, the mean absolute error of
the score after the rally (|near| + |far| points per rally) and the share with the exact
score; coverage is the share of matched, labelled rallies given any winner.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

from shuttlesense.config import BACKEND_DIR
from shuttlesense.evaluation import rally_boundary_accuracy
from shuttlesense.referee import apply_rallies
from shuttlesense.schema import Rally, ScorePair, load_record

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"
SIDES = ("near", "far")
SOURCES = ("landing", "serve", "sequence", "withheld", "undecided")


def decided_by(rally: Rally) -> str:
    """What decided a predicted rally, from its review note and winner (D47)."""
    review = rally.review or ""
    if review.startswith("Scored for ") and "from where the servers stood" in review:
        return "sequence"
    if review.startswith("Scored for ") and "from the next serve" in review:
        return "serve"
    if review.startswith("The landing gives the rally to "):
        return "withheld"
    return "undecided" if rally.winner is None else "landing"


def _rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as f:
        return [{k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
                for row in csv.DictReader(f)]  # fmt: skip


def _side(value: str | None) -> str | None:
    value = (value or "").lower()
    return value if value in SIDES else None


def read_rally_labels(path: Path) -> list[dict[str, Any]]:
    """Labelled rallies in time order: {start_s, end_s, winner}."""
    rallies = [
        {
            "start_s": float(r["start_s"]),
            "end_s": float(r["end_s"]),
            "winner": _side(r.get("winner")),
        }
        for r in _rows(path)
        if r.get("start_s") and r.get("end_s")
    ]
    return sorted(rallies, key=lambda r: r["start_s"])


def read_predicted(path: Path) -> list[dict[str, Any]]:
    """Predicted rallies from record.json or rallies.csv: {start_s, end_s, winner, score}."""
    if path.suffix.lower() == ".json":
        record = load_record(path.read_text(encoding="utf-8"))
        fps = record.fps or 30.0
        return [
            {
                "start_s": r.start_frame / fps,
                "end_s": r.end_frame / fps,
                "winner": r.winner,
                "score": None if r.score_after is None else [r.score_after.near, r.score_after.far],
                "decided_by": decided_by(r),
            }
            for r in record.rallies
        ]
    out = []
    for r in _rows(path):
        has_score = r.get("score_near") and r.get("score_far")
        out.append({
            "start_s": float(r["start_s"]),
            "end_s": float(r["end_s"]),
            "winner": _side(r.get("winner")),
            "score": [int(r["score_near"]), int(r["score_far"])] if has_score else None,
            "decided_by": None,  # rallies.csv does not say
        })  # fmt: skip
    return out


def match_rallies(
    predicted: list[dict[str, Any]], truth: list[dict[str, Any]], tolerance_s: float
) -> dict[int, int]:
    """{truth index: predicted index}, the same rule as rally_boundary_accuracy."""
    used: set[int] = set()
    pairs: dict[int, int] = {}
    for j, t in enumerate(truth):
        for i, p in enumerate(predicted):
            if (i not in used and abs(p["start_s"] - t["start_s"]) <= tolerance_s
                    and abs(p["end_s"] - t["end_s"]) <= tolerance_s):  # fmt: skip
                used.add(i)
                pairs[j] = i
                break
    return pairs


def true_scores(truth: list[dict[str, Any]], start: ScorePair) -> list[list[int] | None]:
    rallies = [Rally(index=i, start_frame=0, end_frame=0, winner=t["winner"])
               for i, t in enumerate(truth)]  # fmt: skip
    apply_rallies(rallies, start)
    return [None if r.score_after is None else [r.score_after.near, r.score_after.far]
            for r in rallies]  # fmt: skip


def evaluate_clip(
    predicted: list[dict[str, Any]],
    truth: list[dict[str, Any]],
    tolerance_s: float = 1.0,
    start: ScorePair | None = None,
) -> dict[str, Any]:
    pairs = match_rallies(predicted, truth, tolerance_s)
    accuracy = rally_boundary_accuracy(
        [(p["start_s"], p["end_s"]) for p in predicted],
        [(t["start_s"], t["end_s"]) for t in truth],
        tolerance_s,
    )
    scores = true_scores(truth, start or ScorePair())
    rows = []
    for j, t in enumerate(truth):
        p = predicted[pairs[j]] if j in pairs else None
        rows.append({
            "truth": [round(t["start_s"], 3), round(t["end_s"], 3)],
            "pred": None if p is None else [round(p["start_s"], 3), round(p["end_s"], 3)],
            "winner_true": t["winner"],
            "winner_pred": None if p is None else p["winner"],
            "score_true": scores[j],
            "score_pred": None if p is None else p["score"],
            "decided_by": None if p is None else p.get("decided_by"),
        })  # fmt: skip
    judged = [r for r in rows if r["pred"] is not None and r["winner_true"]]
    winners_ok = sum(1 for r in judged if r["winner_pred"] == r["winner_true"])
    pred_scores = [p["score"] for p in predicted if p["score"] is not None]
    true_final = next((s for s in reversed(scores) if s is not None), None)
    errors = score_errors(rows)
    return {
        "truth_rallies": len(truth),
        "pred_rallies": len(predicted),
        "matched": len(pairs),
        "boundary_accuracy": accuracy,
        "winner_accuracy": winners_ok / len(judged) if judged else None,
        "score_sequence_true": scores,
        "score_sequence_pred": [p["score"] for p in predicted],
        "final_score_true": true_final,
        "final_score_pred": pred_scores[-1] if pred_scores else None,
        "by_source": by_source(rows),
        **errors,
        "rallies": rows,
    }


def score_errors(rows: list[dict[str, Any]]) -> dict[str, Any]:
    """Score MAE (points per rally), exact-score rate and winner coverage on matched rallies."""
    scored = [r for r in rows if r["score_pred"] is not None and r["score_true"] is not None]
    diffs = [abs(r["score_pred"][0] - r["score_true"][0])
             + abs(r["score_pred"][1] - r["score_true"][1]) for r in scored]  # fmt: skip
    labelled = [r for r in rows if r["pred"] is not None and r["winner_true"]]
    return {
        "score_mae": sum(diffs) / len(diffs) if diffs else None,
        "exact_score_rate": sum(d == 0 for d in diffs) / len(diffs) if diffs else None,
        "coverage": (
            sum(r["winner_pred"] is not None for r in labelled) / len(labelled)
            if labelled
            else None
        ),
    }


def by_source(rows: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """{source: {rallies, judged, correct, accuracy}} over matched rallies with a source.

    For landing and serve, accuracy is the share of awarded points that went to the right
    side; withheld and undecided rallies award nothing, so theirs is None.
    """
    out: dict[str, dict[str, Any]] = {}
    for source in SOURCES:
        mine = [r for r in rows if r["pred"] is not None and r.get("decided_by") == source]
        judged = [r for r in mine if r["winner_true"] and r["winner_pred"]]
        correct = sum(1 for r in judged if r["winner_pred"] == r["winner_true"])
        out[source] = {
            "rallies": len(mine),
            "judged": len(judged),
            "correct": correct,
            "accuracy": correct / len(judged) if judged else None,
        }
    return out


def _score(s: list[int] | None) -> str:
    return "-" if s is None else f"{s[0]}-{s[1]}"


def _pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.1%}"


def _num(value: float | None) -> str:
    return "n/a" if value is None else f"{value:.2f}"


def to_markdown(results: dict[str, dict[str, Any]], tolerance_s: float, overall: dict) -> str:
    lines = [
        "# Rally boundaries and score",
        "",
        f"A rally is correct when start and end are both within +-{tolerance_s:g} s.",
        "",
        "| Clip | Labelled | Predicted | Correct | Boundary acc. | Winner acc. | "
        "Score MAE | Exact score | Coverage | Final score (true / pred) |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for name, r in results.items():
        lines.append(
            f"| {name} | {r['truth_rallies']} | {r['pred_rallies']} | {r['matched']} | "
            f"{_pct(r['boundary_accuracy'])} | {_pct(r['winner_accuracy'])} | "
            f"{_num(r.get('score_mae'))} | {_pct(r.get('exact_score_rate'))} | "
            f"{_pct(r.get('coverage'))} | "
            f"{_score(r['final_score_true'])} / {_score(r['final_score_pred'])} |"
        )
    lines += [
        f"| **all** | {overall['truth_rallies']} | {overall['pred_rallies']} | "
        f"{overall['matched']} | **{_pct(overall['boundary_accuracy'])}** | "
        f"{_pct(overall['winner_accuracy'])} | **{_num(overall.get('score_mae'))}** | "
        f"{_pct(overall.get('exact_score_rate'))} | {_pct(overall.get('coverage'))} | |",
        "",
    ]
    sources = overall.get("by_source")
    if sources and any(v["rallies"] for v in sources.values()):
        lines += ["| Decided by | Rallies | Judged | Correct | Accuracy |",
                  "| --- | ---: | ---: | ---: | ---: |"]  # fmt: skip
        for source, v in sources.items():
            lines.append(f"| {source} | {v['rallies']} | {v['judged']} | {v['correct']} | "
                         f"{_pct(v['accuracy'])} |")  # fmt: skip
        lines.append("")
    for name, r in results.items():
        lines += [f"## {name}", "", "| # | Label (s) | Predicted (s) | Winner (true / pred) | "
                  "Score (true / pred) |", "| ---: | --- | --- | --- | --- |"]  # fmt: skip
        for k, row in enumerate(r["rallies"]):
            t = row["truth"]
            p = "missed" if row["pred"] is None else f"{row['pred'][0]:.2f}-{row['pred'][1]:.2f}"
            lines.append(
                f"| {k} | {t[0]:.2f}-{t[1]:.2f} | {p} | {row['winner_true'] or '-'} / "
                f"{row['winner_pred'] or '-'} | {_score(row['score_true'])} / "
                f"{_score(row['score_pred'])} |"
            )
        lines.append("")
    return "\n".join(lines)


def pooled(results: dict[str, dict[str, Any]]) -> dict[str, Any]:
    truth = sum(r["truth_rallies"] for r in results.values())
    matched = sum(r["matched"] for r in results.values())
    judged = [row for r in results.values() for row in r["rallies"]
              if row["pred"] is not None and row["winner_true"]]  # fmt: skip
    ok = sum(1 for row in judged if row["winner_pred"] == row["winner_true"])
    return {
        "truth_rallies": truth,
        "pred_rallies": sum(r["pred_rallies"] for r in results.values()),
        "matched": matched,
        "boundary_accuracy": matched / truth if truth else 0.0,
        "winner_accuracy": ok / len(judged) if judged else None,
        "by_source": by_source([row for r in results.values() for row in r["rallies"]]),
        **score_errors([row for r in results.values() for row in r["rallies"]]),
    }


def parse_score(text: str) -> ScorePair:
    near, _, far = text.partition("-")
    return ScorePair(near=int(near), far=int(far or 0))


def write_report(data: dict[str, Any], markdown: str, out_md: Path) -> None:
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(markdown, encoding="utf-8")
    out_md.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pred", type=Path, action="append", required=True)
    parser.add_argument("--gt", type=Path, action="append", required=True)
    parser.add_argument("--tolerance", type=float, default=1.0, help="seconds")
    parser.add_argument("--start-score", type=parse_score, default=ScorePair(), help="near-far")
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "rallies.md")
    args = parser.parse_args()
    if len(args.pred) != len(args.gt):
        raise SystemExit("give one --gt per --pred")

    results = {
        gt.stem: evaluate_clip(read_predicted(pred), read_rally_labels(gt), args.tolerance,
                               args.start_score)
        for pred, gt in zip(args.pred, args.gt, strict=True)
    }  # fmt: skip
    overall = pooled(results)
    markdown = to_markdown(results, args.tolerance, overall)
    print(markdown)
    data = {"tolerance_s": args.tolerance, "overall": overall, "clips": results}
    write_report(data, markdown, args.out)
    print(f"wrote {args.out} and {args.out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
