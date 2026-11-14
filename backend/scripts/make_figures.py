"""Stroke classifier results: tables and figures from the training metrics (T3.9, T3.12, T11.6).

Usage: python scripts/make_figures.py [--metrics-dir outputs] [--out-dir ../docs/results]
                [--algorithms cnn,lstm,rf] [--note "text for the report's first paragraph"]

For each algorithm, reads every <metrics>_seed<N>.json and <metrics>_pose_only_seed<N>.json
written by train_stroke_classifier.py (names from configs/stroke_<algorithm>.yaml
output.metrics) and writes:

    docs/results/strokes.md                 test accuracy, macro accuracy and macro F1 as
                                            mean +- std over seeds, per model (and pose-only
                                            where it was run); per-class F1; the most
                                            confused class pairs
    docs/results/strokes.json               the same numbers
    docs/results/strokes_confusion_<model>.png   row-normalized confusion matrix, summed
                                            over the model's seeds
    docs/results/strokes_per_class_f1.png   per-class F1 by model
    docs/results/strokes_models.png         macro accuracy and F1 by model

With --config one model's runs are read as before ("full" vs "pose_only": the figures are
strokes_confusion.png and strokes_ablation.png). Needs matplotlib (requirements/ml.txt). Only
files with a "test" section count.
"""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.config import BACKEND_DIR, load_config

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"
VARIANTS = {
    "full": "pose + shuttle",
    "pose_only": "pose only",
    "cnn": "1D CNN",
    "lstm": "LSTM",
    "rf": "Random Forest",
    "cnn_pose_only": "1D CNN, pose only",
    "lstm_pose_only": "LSTM, pose only",
    "rf_pose_only": "Random Forest, pose only",
}
ALGORITHMS = ("cnn", "lstm", "rf")
SUMMARY_KEYS = ("accuracy", "macro_accuracy", "macro_f1")


def collect(metrics_dir: Path, stem: str) -> dict[str, list[dict[str, Any]]]:
    """{"full": [run, ...], "pose_only": [...]} for runs with test metrics, by seed."""
    pattern = re.compile(rf"^{re.escape(stem)}(_pose_only)?_seed(\d+)\.json$")
    runs: dict[str, list[dict[str, Any]]] = {"full": [], "pose_only": []}
    for path in sorted(metrics_dir.glob(f"{stem}*_seed*.json")):
        m = pattern.match(path.name)
        if not m:
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        if "test" not in data:
            continue
        data.setdefault("seed", int(m.group(2)))
        runs["pose_only" if m.group(1) else "full"].append(data)
    for v in runs.values():
        v.sort(key=lambda r: r["seed"])
    return runs


def collect_models(
    algorithms: list[str], metrics_dir: Path | None = None
) -> tuple[dict[str, list[dict[str, Any]]], list[str]]:
    """({"cnn": [run, ...], "lstm": [...], "cnn_pose_only": [...]}, classes) for the
    algorithms whose config and metrics exist; variants without runs are left out."""
    runs: dict[str, list[dict[str, Any]]] = {}
    extra: dict[str, list[dict[str, Any]]] = {}
    classes: list[str] = []
    for name in algorithms:
        config_path = BACKEND_DIR / "configs" / f"stroke_{name}.yaml"
        if not config_path.is_file():
            continue
        cfg = load_config(config_path)
        classes = classes or list(cfg["data"]["classes"])
        metrics = BACKEND_DIR / cfg["output"]["metrics"]
        found = collect(metrics_dir or metrics.parent, metrics.stem)
        if found["full"]:
            runs[name] = found["full"]
        if found["pose_only"]:
            extra[f"{name}_pose_only"] = found["pose_only"]
    return {**runs, **extra}, classes


def _mean_std(values: list[float]) -> dict[str, float]:
    return {
        "mean": statistics.fmean(values),
        "std": statistics.stdev(values) if len(values) > 1 else 0.0,
    }


def summarize(runs: dict[str, list[dict[str, Any]]], classes: list[str]) -> dict[str, Any]:
    out: dict[str, Any] = {"classes": classes, "variants": {}}
    for variant, items in runs.items():
        if not items:
            continue
        tests = [r["test"] for r in items]
        cm = np.sum([np.asarray(t["confusion_matrix"]) for t in tests], axis=0)
        out["variants"][variant] = {
            "seeds": [r["seed"] for r in items],
            **{k: _mean_std([t[k] for t in tests]) for k in SUMMARY_KEYS},
            "per_class_f1": {
                c: _mean_std([t["per_class"][c]["f1"] for t in tests]) for c in classes
            },
            "confusion_matrix": cm.tolist(),
            "confused_pairs": confused_pairs(cm, classes),
        }
    return out


def confused_pairs(cm: np.ndarray, classes: list[str], top: int = 3) -> list[dict[str, Any]]:
    """The largest off-diagonal cells as a share of the true class."""
    rows = cm.sum(axis=1, keepdims=True)
    with np.errstate(invalid="ignore", divide="ignore"):
        rate = np.where(rows > 0, cm / rows, 0.0)
    np.fill_diagonal(rate, 0.0)
    order = np.dstack(np.unravel_index(np.argsort(-rate, axis=None), rate.shape))[0]
    pairs = []
    for t, p in order[:top]:
        if rate[t, p] <= 0:
            break
        pairs.append({"true": classes[t], "predicted": classes[p], "share": float(rate[t, p])})
    return pairs


def _fmt(ms: dict[str, float]) -> str:
    return f"{ms['mean']:.1%} ± {ms['std']:.1%}"


def to_markdown(summary: dict[str, Any], figures: list[str], note: str | None = None) -> str:
    variants = summary["variants"]
    lines = [
        "# Stroke classifier results",
        "",
        "Test matches only, mean ± std over seeds. Generated by `scripts/make_figures.py` "
        "from the `train_stroke_classifier.py` metrics files.",
        "",
        *([note, ""] if note else []),
        "| Model | Seeds | Accuracy | Macro accuracy | Macro F1 |",
        "| --- | --- | ---: | ---: | ---: |",
    ]
    for key, v in variants.items():
        seeds = ", ".join(str(s) for s in v["seeds"])
        lines.append(
            f"| {VARIANTS[key]} | {seeds} | {_fmt(v['accuracy'])} | "
            f"{_fmt(v['macro_accuracy'])} | {_fmt(v['macro_f1'])} |"
        )
    lines += ["", "## Per-class F1", "", "| Class | " + " | ".join(
        VARIANTS[k] for k in variants) + " |", "| --- |" + " ---: |" * len(variants)]  # fmt: skip
    for c in summary["classes"]:
        cells = " | ".join(_fmt(v["per_class_f1"][c]) for v in variants.values())
        lines.append(f"| {c} | {cells} |")
    for key, v in variants.items():
        if v["confused_pairs"]:
            lines += ["", f"Most confused ({VARIANTS[key]}): " + "; ".join(
                f"{p['true']} → {p['predicted']} {p['share']:.0%}" for p in v["confused_pairs"]
            )]  # fmt: skip
    if figures:
        lines += ["", "## Figures", ""] + [f"![{f}]({f})" for f in figures]
    lines.append("")
    return "\n".join(lines)


def plot(summary: dict[str, Any], out_dir: Path) -> list[str]:
    """Write the PNGs; returns their file names."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    classes, variants, written = summary["classes"], summary["variants"], []
    for key in [k for k in variants if not k.endswith("pose_only")]:
        cm = np.asarray(variants[key]["confusion_matrix"], float)
        rows = cm.sum(axis=1, keepdims=True)
        norm = np.divide(cm, rows, out=np.zeros_like(cm), where=rows > 0)
        fig, ax = plt.subplots(figsize=(5.5, 4.5))
        im = ax.imshow(norm, cmap="Blues", vmin=0, vmax=1)
        ax.set_xticks(range(len(classes)), classes, rotation=45, ha="right")
        ax.set_yticks(range(len(classes)), classes)
        ax.set_xlabel("Predicted")
        ax.set_ylabel("True")
        for i in range(len(classes)):
            for j in range(len(classes)):
                color = "white" if norm[i, j] > 0.5 else "black"
                ax.text(
                    j, i, f"{norm[i, j]:.2f}", ha="center", va="center", fontsize=8, color=color
                )
        fig.colorbar(im, ax=ax, fraction=0.046)
        ax.set_title(f"Confusion ({VARIANTS[key]}, row-normalized)")
        name = "strokes_confusion.png" if key == "full" else f"strokes_confusion_{key}.png"
        written.append(_save(fig, out_dir / name))

    x = np.arange(len(classes))
    width = 0.8 / max(len(variants), 1)
    fig, ax = plt.subplots(figsize=(6.5, 3.5))
    for k, (key, v) in enumerate(variants.items()):
        means = [v["per_class_f1"][c]["mean"] for c in classes]
        stds = [v["per_class_f1"][c]["std"] for c in classes]
        ax.bar(x + (k - (len(variants) - 1) / 2) * width, means, width, yerr=stds,
               label=VARIANTS[key], capsize=3)  # fmt: skip
    ax.set_xticks(x, classes)
    ax.set_ylim(0, 1)
    ax.set_ylabel("F1")
    ax.legend()
    ax.set_title("Per-class F1 on test matches")
    written.append(_save(fig, out_dir / "strokes_per_class_f1.png"))

    if len(variants) > 1:
        metrics = ("macro_accuracy", "macro_f1")
        x = np.arange(len(metrics))
        ablation = set(variants) == {"full", "pose_only"}
        bar = 0.8 / len(variants)
        fig, ax = plt.subplots(figsize=(4.5 if ablation else 6.5, 3.5))
        for k, (key, v) in enumerate(variants.items()):
            ax.bar(x + (k - (len(variants) - 1) / 2) * bar, [v[m]["mean"] for m in metrics], bar,
                   yerr=[v[m]["std"] for m in metrics], label=VARIANTS[key], capsize=3)  # fmt: skip
        ax.set_xticks(x, ["macro accuracy", "macro F1"])
        ax.set_ylim(0, 1)
        ax.legend(loc="lower right")
        ax.set_title("Ablation: shuttle trajectory features" if ablation else "Stroke models")
        name = "strokes_ablation.png" if ablation else "strokes_models.png"
        written.append(_save(fig, out_dir / name))
    return written


def _save(fig, path: Path) -> str:
    import matplotlib.pyplot as plt

    path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)
    return path.name


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=None, help="one model: full vs pose-only")
    parser.add_argument("--algorithms", default=",".join(ALGORITHMS))
    parser.add_argument("--metrics-dir", type=Path, default=None, help="default: output.metrics")
    parser.add_argument("--out-dir", type=Path, default=RESULTS_DIR)
    parser.add_argument("--note", default=None, help="a paragraph for the top of strokes.md")
    args = parser.parse_args()
    if args.config:
        cfg = load_config(args.config)
        metrics = BACKEND_DIR / cfg["output"]["metrics"]
        runs = collect(args.metrics_dir or metrics.parent, metrics.stem)
        classes = list(cfg["data"]["classes"])
    else:
        names = [a for a in args.algorithms.split(",") if a]
        runs, classes = collect_models(names, args.metrics_dir)
    if not any(runs.values()):
        raise SystemExit("no *_seed*.json with test metrics; train first")
    summary = summarize(runs, classes)
    figures = plot(summary, args.out_dir)
    markdown = to_markdown(summary, figures, args.note)
    (args.out_dir / "strokes.md").write_text(markdown, encoding="utf-8")
    (args.out_dir / "strokes.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    # A Windows console or pipe may not be UTF-8; the report itself is already written.
    sys.stdout.reconfigure(errors="replace")
    print(markdown)
    print(f"wrote strokes.md, strokes.json and {len(figures)} figures to {args.out_dir}")


if __name__ == "__main__":
    main()
