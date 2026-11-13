"""Line-call evaluation against labelled landings (T8.12, FR-20).

Usage: python scripts/eval_line_calls.py --pred out/record.json --gt labels/rally01.csv
                [--pred ... --gt ...] [--tolerance 1.0] [--near-line-cm 20]
                [--out ../docs/results/line_calls.md]

--pred is a record.json from a run with the referee stage and court calibration (an upload
or a saved live session). Pair each with one --gt in the same order.

Ground truth, either:
- a T7.1 label file (labels/<clip>.csv): rally rows with start_s, end_s and in_out
  (in | out | empty), plus optional landing_x_m, landing_y_m (court meters, measured or
  read off the video by hand) used for the near-line numbers;
- a ShuttleSet set CSV (--gt-format shuttleset, with --fps of the match video): the last
  stroke of each rally gives its end time, and lose_reason gives the label. Only the
  reasons that say where the shuttle landed are used (see SHUTTLESET_CALLS); net faults and
  the rest are skipped. Check the mapping against the CSVs you downloaded before reporting.
  Its landing_x, landing_y are pixels in the match video (--annotation-size, 1280x720 by
  default). When the paired record has a calibrated court and was made from the same
  framing, they are projected to court meters with the record's homography and used as the
  labelled landing; without a court they are left out.

A labelled rally is matched to a predicted rally as in eval_rallies.py. On matched rallies
with both a label and a call:
- precision and recall for IN and for OUT count only certain calls (UNCERTAIN ones are the
  ones the app asks the user to confirm), and coverage says how many were certain;
- the near-line false-call rate is the share of certain calls on landings within
  --near-line-cm of a line that are wrong. Each call uses the labelled landing position when
  its label has one, otherwise the predicted margin, and the report says which (or both).
  A labelled landing is measured against the same lines as the call: the service court
  for a rally that is only a serve, the rally lines otherwise.
Nothing here measures accuracy unless labels exist: with no labelled landings the report
says so instead of printing numbers.
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.config import BACKEND_DIR
from shuttlesense.court.homography import image_to_court
from shuttlesense.court.lines import play_bounds
from shuttlesense.referee.linecalls import bounds_for, signed_margin
from shuttlesense.schema import load_record

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"

# ShuttleSet lose_reason values that say where the shuttle landed (others: net, faults...).
SHUTTLESET_CALLS = {"出界": "out", "對手落地致勝": "in", "落點判斷失誤": "in"}


def _eval_rallies():
    spec = importlib.util.spec_from_file_location(
        "eval_rallies", Path(__file__).with_name("eval_rallies.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as f:
        return [{k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
                for row in csv.DictReader(f)]  # fmt: skip


def read_labels(path: Path) -> list[dict[str, Any]]:
    """T7.1 rally rows: {start_s, end_s, call, landing}."""
    out = []
    for r in _rows(path):
        if not (r.get("start_s") and r.get("end_s")):
            continue
        call = r.get("in_out", "").lower()
        has_xy = r.get("landing_x_m") and r.get("landing_y_m")
        out.append({
            "start_s": float(r["start_s"]),
            "end_s": float(r["end_s"]),
            "call": call if call in ("in", "out") else None,
            "landing": (float(r["landing_x_m"]), float(r["landing_y_m"])) if has_xy else None,
        })  # fmt: skip
    return sorted(out, key=lambda r: r["start_s"])


ToCourt = Callable[[float, float], tuple[float, float] | None]


def court_mapper(pred: Path, annotation_size: tuple[int, int] = (1280, 720)) -> ToCourt | None:
    """Annotation pixels -> court meters through the record's homography; None without a
    calibrated court. The record must show the same framing as the annotated video; a
    different resolution is scaled. A pixel near the homography's horizon has no court point
    (None): it would map to inf/NaN, which JSON cannot hold."""
    record = load_record(pred.read_text(encoding="utf-8"))
    if record.court is None or not record.width or not record.height:
        return None
    h = np.asarray(record.court.homography, dtype=float)
    sx, sy = record.width / annotation_size[0], record.height / annotation_size[1]

    def to_court(x: float, y: float) -> tuple[float, float] | None:
        mx, my = image_to_court(h, np.array([[x * sx, y * sy]]))[0]
        if not (np.isfinite(mx) and np.isfinite(my)):
            return None
        return round(float(mx), 3), round(float(my), 3)

    return to_court


def read_shuttleset(
    path: Path, fps: float, to_court: ToCourt | None = None
) -> list[dict[str, Any]]:
    """One label per rally from a ShuttleSet set CSV (start/end from its stroke frames).

    With `to_court`, the landing pixel of the stroke that ended the rally becomes the
    labelled landing in court meters.
    """
    rallies: dict[int, dict[str, Any]] = {}
    for r in _rows(path):
        if not r.get("rally") or not r.get("frame_num"):
            continue
        index = int(float(r["rally"]))
        t = float(r["frame_num"]) / fps
        rally = rallies.setdefault(index, {"start_s": t, "end_s": t, "call": None, "landing": None})
        rally["start_s"], rally["end_s"] = min(rally["start_s"], t), max(rally["end_s"], t)
        reason = r.get("lose_reason", "")
        if reason in SHUTTLESET_CALLS:
            rally["call"] = SHUTTLESET_CALLS[reason]
            if to_court and r.get("landing_x") and r.get("landing_y"):
                rally["landing"] = to_court(float(r["landing_x"]), float(r["landing_y"]))
    return [rallies[k] for k in sorted(rallies)]


def read_predicted(path: Path) -> list[dict[str, Any]]:
    """Predicted rallies with their line call: {start_s, end_s, call, uncertain, margin_cm,
    court, bounds}; bounds are the lines the call was made against."""
    record = load_record(path.read_text(encoding="utf-8"))
    fps = record.fps or 30.0
    calls = {c.rally_index: c for c in record.line_calls}
    out = []
    for r in record.rallies:
        c = calls.get(r.index)
        court = "singles" if c is None else c.court
        out.append({
            "start_s": r.start_frame / fps,
            "end_s": r.end_frame / fps,
            "call": None if c is None else c.call,  # the automated call, before any override
            "uncertain": None if c is None else c.uncertain,
            "margin_cm": None if c is None else c.margin_cm,
            "court": court,
            "bounds": bounds_for(record, r, court)[0],
        })  # fmt: skip
    return out


def _ratio(num: int, den: int) -> float | None:
    return num / den if den else None


def match_on_start(
    predicted: list[dict[str, Any]], truth: list[dict[str, Any]], tolerance_s: float
) -> dict[int, int]:
    """{truth index: predicted index} by rally start only, nearest first.

    ShuttleSet's rally end is the frame of the last stroke, while a predicted rally ends at
    the landing or rest, about one shot's flight later; matching ends too would drop most
    rallies that ended on a clear or a lift."""
    used: set[int] = set()
    pairs: dict[int, int] = {}
    for j, t in enumerate(truth):
        free = [(abs(p["start_s"] - t["start_s"]), i) for i, p in enumerate(predicted)
                if i not in used and abs(p["start_s"] - t["start_s"]) <= tolerance_s]  # fmt: skip
        if free:
            i = min(free)[1]
            used.add(i)
            pairs[j] = i
    return pairs


def evaluate(
    predicted: list[dict[str, Any]],
    truth: list[dict[str, Any]],
    tolerance_s: float = 1.0,
    near_line_cm: float = 20.0,
    match_end: bool = True,
) -> dict[str, Any]:
    if match_end:
        pairs = _eval_rallies().match_rallies(predicted, truth, tolerance_s)
    else:
        pairs = match_on_start(predicted, truth, tolerance_s)
    rows = []
    for j, t in enumerate(truth):
        if t["call"] is None:
            continue
        p = predicted[pairs[j]] if j in pairs else None
        true_margin = None
        if t["landing"] is not None:
            bounds = p.get("bounds") or play_bounds(p["court"]) if p else play_bounds("singles")
            true_margin = signed_margin(t["landing"], bounds) * 100
        rows.append({
            "end_s": round(t["end_s"], 3),
            "matched": p is not None,
            "label": t["call"],
            "call": None if p is None else p["call"],
            "uncertain": None if p is None else p["uncertain"],
            "margin_cm_pred": None if p is None else p["margin_cm"],
            "margin_cm_true": None if true_margin is None else round(true_margin, 1),
        })  # fmt: skip
    return {"rows": rows, **summarize(rows, near_line_cm)}


def summarize(rows: list[dict[str, Any]], near_line_cm: float) -> dict[str, Any]:
    called = [r for r in rows if r["call"] is not None]
    certain = [r for r in called if not r["uncertain"]]
    out: dict[str, Any] = {
        "labelled": len(rows),
        "unmatched": sum(not r.get("matched", True) for r in rows),
        "called": len(called),
        "certain": len(certain),
        "uncertain_share": _ratio(len(called) - len(certain), len(called)),
        "accuracy_certain": _ratio(sum(r["call"] == r["label"] for r in certain), len(certain)),
    }
    for cls in ("in", "out"):
        tp = sum(r["call"] == cls and r["label"] == cls for r in certain)
        out[f"precision_{cls}"] = _ratio(tp, sum(r["call"] == cls for r in certain))
        out[f"recall_{cls}"] = _ratio(tp, sum(r["label"] == cls for r in certain))

    def margin(r: dict[str, Any]) -> float | None:
        true = r["margin_cm_true"]
        return true if true is not None else r["margin_cm_pred"]

    near = [r for r in certain if margin(r) is not None and abs(margin(r)) <= near_line_cm]
    labelled = sum(r["margin_cm_true"] is not None for r in near)
    basis = (
        "labelled landing" if near and labelled == len(near)
        else "predicted margin" if not labelled
        else f"labelled landing ({labelled}) and predicted margin ({len(near) - labelled})"
    )  # fmt: skip
    out["near_line"] = {
        "basis": basis,
        "within_cm": near_line_cm,
        "certain_calls": len(near),
        "false_call_rate": _ratio(sum(r["call"] != r["label"] for r in near), len(near)),
    }
    return out


def _pct(v: float | None) -> str:
    return "–" if v is None else f"{v:.1%}"


def to_markdown(clips: dict[str, dict[str, Any]], overall: dict[str, Any], args: Any) -> str:
    lines = ["# Line calls (T8.12)", ""]
    if overall["labelled"] == 0:
        lines += [
            "No labelled landings were given, so no accuracy is reported.",
            "",
            "Label rally rows with `in_out` (and `landing_x_m`, `landing_y_m` where known) in "
            "the T7.1 files, then run `scripts/eval_line_calls.py` again.",
        ]
        return "\n".join(lines) + "\n"
    n = overall["near_line"]
    lines += [
        f"Matched within ±{args.tolerance} s"
        f"{' on the rally start' if getattr(args, 'gt_format', '') == 'shuttleset' else ''}. "
        "Precision and recall count certain calls only; "
        "UNCERTAIN calls go to the user.",
        "",
        "| Clip | Labelled | Called | Certain | IN P / R | OUT P / R | Accuracy (certain) |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for name, r in [*clips.items(), ("**all**", overall)]:
        lines.append(
            f"| {name} | {r['labelled']} | {r['called']} | {r['certain']} | "
            f"{_pct(r['precision_in'])} / {_pct(r['recall_in'])} | "
            f"{_pct(r['precision_out'])} / {_pct(r['recall_out'])} | "
            f"{_pct(r['accuracy_certain'])} |"
        )
    lines += [
        "",
        f"Near-line (within {n['within_cm']:g} cm, by {n['basis']}): {n['certain_calls']} "
        f"certain calls, false-call rate {_pct(n['false_call_rate'])}. "
        f"Uncertain share overall: {_pct(overall['uncertain_share'])}.",
        "",
        f"{overall['unmatched']} of {overall['labelled']} labelled rallies matched no predicted "
        "rally; they count as not called.",
    ]
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--pred", type=Path, action="append", required=True)
    parser.add_argument("--gt", type=Path, action="append", required=True)
    parser.add_argument("--gt-format", choices=["labels", "shuttleset"], default="labels")
    parser.add_argument("--fps", type=float, default=30.0, help="ShuttleSet video fps")
    parser.add_argument(
        "--annotation-size",
        default="1280x720",
        help="ShuttleSet: frame size the landing pixels were annotated on",
    )
    parser.add_argument("--tolerance", type=float, default=1.0, help="seconds")
    parser.add_argument("--near-line-cm", type=float, default=20.0)
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "line_calls.md")
    args = parser.parse_args()
    if len(args.pred) != len(args.gt):
        raise SystemExit("give one --gt per --pred")
    clips = {}
    for pred, gt in zip(args.pred, args.gt, strict=True):
        if args.gt_format == "shuttleset":
            width, height = (int(v) for v in args.annotation_size.lower().split("x"))
            truth = read_shuttleset(gt, args.fps, court_mapper(pred, (width, height)))
        else:
            truth = read_labels(gt)
        name, n = gt.stem, 2
        while name in clips:  # two label files with the same name in different folders
            name, n = f"{gt.stem} ({n})", n + 1
        clips[name] = evaluate(read_predicted(pred), truth, args.tolerance, args.near_line_cm,
                               match_end=args.gt_format != "shuttleset")  # fmt: skip
    rows = [r for c in clips.values() for r in c["rows"]]
    overall = summarize(rows, args.near_line_cm)
    markdown = to_markdown(clips, overall, args)
    print(markdown)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(markdown, encoding="utf-8")
    data = {"tolerance_s": args.tolerance, "overall": overall, "clips": clips}
    args.out.with_suffix(".json").write_text(
        json.dumps(data, indent=2, allow_nan=False) + "\n", encoding="utf-8"
    )
    print(f"wrote {args.out} and {args.out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
