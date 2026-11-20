"""Fit the stroke ensemble's member weights on out-of-fold predictions (D41).

Usage:
    python scripts/fit_stroke_ensemble.py --cnn outputs/cv/<name>_oof.npz
        --lstm outputs/cv/<name>_oof.npz --rf outputs/cv/<name>_oof.npz [--write]

Each file comes from scripts/cv_strokes.py on the same pooled windows and folds, so every
window has a prediction from a model that never saw its match. The weights (a grid over the
simplex in steps of 0.1) and the averaging rule (plain mean or weighted geometric mean) with
the best macro-F1 are reported against the equal-weight mean of D37. --write stores them in
weights/strokes/ensemble.json, which strokes/classify.py reads.
"""

from __future__ import annotations

import argparse
import itertools
import json
from pathlib import Path

import numpy as np

from shuttlesense.schema import STROKE_CLASSES
from shuttlesense.strokes.classify import ENSEMBLE_FILE, average_probabilities
from shuttlesense.strokes.metrics import classification_report

BACKEND_DIR = Path(__file__).resolve().parent.parent
MEMBERS = ("cnn", "lstm", "rf")


def nll(probs: np.ndarray, y: np.ndarray) -> float:
    return float(-np.log(np.maximum(probs[np.arange(len(y)), y], 1e-9)).mean())


def score(parts, y, weights, geometric) -> dict:
    classes = list(STROKE_CLASSES)
    probs = average_probabilities(parts, classes, list(weights), geometric=geometric)
    report = classification_report(y, probs.argmax(1), classes)
    return {
        "weights": dict(zip(MEMBERS, (round(w, 2) for w in weights), strict=True)),
        "method": "geometric" if geometric else "mean",
        "macro_f1": report["macro_f1"],
        "accuracy": report["accuracy"],
        "nll": nll(probs, y),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for m in MEMBERS:
        parser.add_argument(f"--{m}", type=Path, required=True)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    loaded = [np.load(getattr(args, m)) for m in MEMBERS]
    y = loaded[0]["y"]
    keep = np.all([np.isfinite(d["probs"]).all(1) for d in loaded], axis=0)
    for d in loaded[1:]:
        if not np.array_equal(d["y"], y):
            raise SystemExit("the out-of-fold files do not cover the same windows")
    y = y[keep]
    parts = [(d["probs"][keep], list(STROKE_CLASSES)) for d in loaded]
    for m, (p, _) in zip(MEMBERS, parts, strict=True):
        alone = classification_report(y, p.argmax(1), list(STROKE_CLASSES))
        print(f"{m}: macro-F1 {alone['macro_f1']:.4f}")
    baseline = score(parts, y, (1.0, 1.0, 1.0), False)
    grid = [
        w for w in itertools.product(np.arange(0, 1.01, 0.1), repeat=3) if abs(sum(w) - 1) < 1e-6
    ]
    results = [score(parts, y, w, g) for w in grid for g in (False, True)]
    best = max(results, key=lambda r: (round(r["macro_f1"], 4), -r["nll"]))
    print(json.dumps({"equal_mean": baseline, "best": best, "windows": int(len(y))}, indent=2))
    if args.write:
        out = BACKEND_DIR / ENSEMBLE_FILE
        out.write_text(
            json.dumps(
                {
                    "weights": best["weights"],
                    "method": best["method"],
                    "oof_macro_f1": round(best["macro_f1"], 4),
                    "equal_mean_oof_macro_f1": round(baseline["macro_f1"], 4),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
