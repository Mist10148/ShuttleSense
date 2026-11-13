"""Estimated shuttle speed per stroke class, for the T5.13 sanity check (T10.5).

Usage: python scripts/speed_report.py RECORD.json [RECORD.json ...]
           [--out ../docs/results/speed.md] [--plot ../docs/results/speed.png]

Reads the hits of one or more clip records (calibrated clips: speeds need a court) and
writes, per stroke class, how many hits have a speed and their median, 10th and 90th
percentile in km/h, as Markdown plus a .json with the same numbers. With --plot it also
draws a box plot (needs matplotlib).

The check itself (T5.13) is that smashes come out fastest and that the medians are in a
plausible order (smash > clear > drop, net shots slowest); these are one-camera estimates
projected onto the court plane, so a high shot reads slower than it is.
"""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path
from typing import Any

from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import STROKE_CLASSES, load_record

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"
UNLABELLED = "unlabelled"


def speeds_by_class(paths: list[Path]) -> dict[str, list[float]]:
    """{stroke class: [km/h, ...]} over every hit with a speed; hits without a stroke label
    go under "unlabelled"."""
    out: dict[str, list[float]] = {}
    for path in paths:
        record = load_record(path.read_text(encoding="utf-8"))
        for hit in record.hits:
            if hit.speed_kmh is None:
                continue
            out.setdefault(hit.stroke or UNLABELLED, []).append(float(hit.speed_kmh))
    return out


def _percentile(values: list[float], q: float) -> float:
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (pos - lo)


def summarize(speeds: dict[str, list[float]]) -> list[dict[str, Any]]:
    """One row per class with hits, in the model's class order."""
    order = [*STROKE_CLASSES, UNLABELLED]
    rows = []
    for cls in sorted(speeds, key=lambda c: order.index(c) if c in order else len(order)):
        values = speeds[cls]
        rows.append({
            "stroke": cls,
            "hits": len(values),
            "median_kmh": round(statistics.median(values), 1),
            "p10_kmh": round(_percentile(values, 0.1), 1),
            "p90_kmh": round(_percentile(values, 0.9), 1),
        })  # fmt: skip
    return rows


def to_markdown(rows: list[dict[str, Any]], sources: list[str]) -> str:
    lines = ["# Estimated shuttle speed by stroke (T5.13)", ""]
    if not rows:
        lines += ["No hit had a speed: the clips need a calibrated court (T5.1)."]
        return "\n".join(lines) + "\n"
    lines += [
        f"From {len(sources)} record(s): {', '.join(sources)}. One-camera estimates on the court "
        "plane: a high shot reads slower than it is.",
        "",
        "| Stroke | Hits | Median km/h | 10th pct | 90th pct |",
        "| --- | --- | --- | --- | --- |",
    ]
    lines += [
        f"| {r['stroke']} | {r['hits']} | {r['median_kmh']} | {r['p10_kmh']} | {r['p90_kmh']} |"
        for r in rows
    ]
    return "\n".join(lines) + "\n"


def plot(speeds: dict[str, list[float]], rows: list[dict[str, Any]], path: Path) -> None:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    names = [r["stroke"] for r in rows]
    fig, ax = plt.subplots(figsize=(6, 3.2), dpi=120)
    ax.boxplot([speeds[n] for n in names])
    ax.set_xticks(range(1, len(names) + 1), names)  # `labels=` was renamed in matplotlib 3.9
    ax.set_ylabel("km/h (estimated)")
    ax.set_title("Shuttle speed by stroke")
    fig.tight_layout()
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path)
    plt.close(fig)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("records", type=Path, nargs="+")
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "speed.md")
    parser.add_argument("--plot", type=Path, default=None, help="box plot PNG")
    args = parser.parse_args()
    speeds = speeds_by_class(args.records)
    rows = summarize(speeds)
    markdown = to_markdown(rows, [p.name for p in args.records])
    print(markdown)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(markdown, encoding="utf-8")
    data = {"records": [str(p) for p in args.records], "rows": rows}
    args.out.with_suffix(".json").write_text(
        json.dumps(data, indent=2, allow_nan=False) + "\n", encoding="utf-8"
    )
    if args.plot and rows:
        plot(speeds, rows, args.plot)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
