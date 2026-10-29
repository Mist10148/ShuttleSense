"""Shuttle tracking accuracy against labelled frames (T2.10).

Usage: python scripts/eval_tracking.py --pred tracking.csv --gt labels.csv [--tolerance 4]
                [--pred raw=raw.csv --pred inpaint=inpaint.csv] [--gt-height 1080]
                [--gt-step 1] [--out ../docs/results/tracking.md]

Both files use the TrackNetV3 CSV layout: columns frame,visible,x,y (or Frame,Visibility,X,Y
as in the Shuttlecock Trajectory Dataset; extra columns such as `source` are ignored; x/y of
invisible rows are ignored). --pred is the pipeline's tracking.csv (normalized frames, 720p
pixels by default); give it several times as name=path to compare raw TrackNet, + InpaintNet
and + interpolation. Only frames listed in --gt are scored, so a hand-labelled subset works.
GT frame numbers are divided by --gt-step when the pipeline downsampled the fps. Pixels are
scaled to 720p (720 / --gt-height, 720 / --pred-height) before the 4 px test.

Metrics (shuttlesense.evaluation.tracking_accuracy): accuracy = frames where both agree on
visibility and, if visible, are within the tolerance; precision/recall of visible detections.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.config import BACKEND_DIR
from shuttlesense.evaluation import tracking_accuracy

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"
REFERENCE_HEIGHT = 720


def read_track(path: Path, *, step: int = 1, height: float = REFERENCE_HEIGHT) -> dict:
    """{frame: (visible, x, y)} with frames divided by step and pixels scaled to 720p."""
    scale = REFERENCE_HEIGHT / height
    track: dict[int, tuple[int, float, float]] = {}
    with path.open(newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            row = {k.strip().lower(): (v or "").strip() for k, v in row.items() if k}
            frame = int(float(row["frame"]))
            if frame % step:
                continue
            visible = int(float(row.get("visible") or row.get("visibility") or 0))
            x = float(row.get("x") or 0) * scale
            y = float(row.get("y") or 0) * scale
            track[frame // step] = (visible, x, y)
    return track


def evaluate(pred: dict, gt: dict, tolerance_px: float = 4.0) -> dict[str, float]:
    """Score the GT frames; a GT frame missing from pred counts as predicted invisible."""
    frames = sorted(gt)
    true = np.array([gt[f] for f in frames], float).reshape(-1, 3)
    got = np.array([pred.get(f, (0, 0.0, 0.0)) for f in frames], float).reshape(-1, 3)
    result = tracking_accuracy(got[:, 1:], got[:, 0], true[:, 1:], true[:, 0], tolerance_px)
    result["frames"] = len(frames)
    result["visible_frames"] = int((true[:, 0] > 0).sum())
    return result


def parse_pred(text: str) -> tuple[str, Path]:
    name, sep, path = text.partition("=")
    return (name, Path(path)) if sep else (Path(text).stem, Path(text))


def to_markdown(results: dict[str, dict[str, float]], tolerance_px: float) -> str:
    lines = [
        "# Shuttle tracking accuracy",
        "",
        f"Tolerance {tolerance_px:g} px at 720p.",
        "",
        "| Prediction | Frames | Visible | Accuracy | Precision | Recall | F1 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for name, m in results.items():
        lines.append(
            f"| {name} | {m['frames']} | {m['visible_frames']} | {m['accuracy']:.3f} | "
            f"{m['precision']:.3f} | {m['recall']:.3f} | {m['f1']:.3f} |"
        )
    return "\n".join(lines) + "\n"


def write_report(data: dict[str, Any], markdown: str, out_md: Path) -> None:
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(markdown, encoding="utf-8")
    out_md.with_suffix(".json").write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pred", action="append", type=parse_pred, required=True,
                        help="tracking.csv, or name=path; repeat to compare")  # fmt: skip
    parser.add_argument("--gt", type=Path, required=True)
    parser.add_argument("--tolerance", type=float, default=4.0, help="pixels at 720p")
    parser.add_argument("--gt-height", type=float, default=REFERENCE_HEIGHT)
    parser.add_argument("--pred-height", type=float, default=REFERENCE_HEIGHT)
    parser.add_argument("--gt-step", type=int, default=1, help="source frames per pred frame")
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "tracking.md")
    args = parser.parse_args()

    gt = read_track(args.gt, step=args.gt_step, height=args.gt_height)
    if not gt:
        raise SystemExit(f"no labelled frames in {args.gt}")
    results = {
        name: evaluate(read_track(path, height=args.pred_height), gt, args.tolerance)
        for name, path in args.pred
    }
    markdown = to_markdown(results, args.tolerance)
    print(markdown)
    write_report({"tolerance_px": args.tolerance, "gt": str(args.gt), "results": results},
                 markdown, args.out)  # fmt: skip
    print(f"wrote {args.out} and {args.out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
