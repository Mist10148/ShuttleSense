"""Dataset statistics and class balance report for the stroke classifier (T3.13).

Usage: python scripts/dataset_stats.py [--clips data/clips] [--splits configs/splits.json]
                [--shuttleset data/shuttleset] [--min-train 500]
                [--out ../docs/results/dataset.md]

Input:  data/clips/<match_id>/index.csv (extract_clips.py), configs/splits.json (make_splits.py;
        optional, matches missing from it are "unassigned") and the ShuttleSet annotations
        data/shuttleset/<match_id>/set*.csv (optional, to count strokes that were annotated
        but never cut into a clip).
Output: counts per class and split, per player (ShuttleSet player id within its match),
        excluded and unknown ShuttleSet types, clip extraction failures per match (annotated
        but not extracted, listed in index.csv but missing on disk), and the classes with
        fewer than --min-train training samples. Markdown tables plus a .json with the numbers.
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from pathlib import Path
from typing import Any

from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import STROKE_CLASSES

DATA_DIR = BACKEND_DIR / "data"
RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"
SPLITS = ("train", "val", "test")


def _count_annotated(match_dir: Path) -> int | None:
    files = sorted(match_dir.glob("set*.csv"))
    if not files:
        return None
    total = 0
    for path in files:
        with path.open(newline="", encoding="utf-8") as f:
            total += sum(1 for _ in csv.DictReader(f))
    return total


def collect(
    clips_dir: Path, splits: dict[str, list[str]], shuttleset_dir: Path | None = None
) -> dict[str, Any]:
    """Count every index.csv row by class, split, player and exclusion reason."""
    from shuttlesense.strokes.labels import english_type, map_label

    split_of = {m: s for s in SPLITS for m in splits.get(s, [])}
    by_split: dict[str, Counter] = {}
    by_player: dict[str, Counter] = {}
    excluded: Counter = Counter()
    unknown: Counter = Counter()
    failures: dict[str, dict[str, int | None]] = {}
    for index in sorted(clips_dir.glob("*/index.csv")):
        match_id = index.parent.name
        split = split_of.get(match_id, "unassigned")
        with index.open(newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        missing = sum(1 for r in rows if not (index.parent / r["clip"]).exists())
        for row in rows:
            raw = english_type(row["shuttleset_type"])
            try:
                label = map_label(raw)
            except KeyError:
                unknown[raw] += 1
                continue
            if label is None:
                excluded[raw] += 1
                continue
            by_split.setdefault(split, Counter())[label] += 1
            by_player.setdefault(f"{match_id}:{row['player']}", Counter())[label] += 1
        annotated = _count_annotated(shuttleset_dir / match_id) if shuttleset_dir else None
        failures[match_id] = {
            "annotated": annotated,
            "indexed": len(rows),
            "not_extracted": None if annotated is None else max(annotated - len(rows), 0),
            "missing_files": missing,
        }
    return {
        "classes": list(STROKE_CLASSES),
        "by_split": {s: dict(c) for s, c in by_split.items()},
        "by_player": {p: dict(c) for p, c in sorted(by_player.items())},
        "excluded": dict(excluded.most_common()),
        "unknown": dict(unknown.most_common()),
        "extraction": failures,
    }


def low_classes(stats: dict[str, Any], min_train: int) -> list[str]:
    train = stats["by_split"].get("train", {})
    return [c for c in stats["classes"] if train.get(c, 0) < min_train]


def _count_table(title: str, rows: dict[str, dict[str, int]], classes: list[str]) -> list[str]:
    lines = [f"## {title}", "", "| | " + " | ".join(classes) + " | total |",
             "| --- |" + " ---: |" * (len(classes) + 1)]  # fmt: skip
    totals: Counter = Counter()
    for name, counts in rows.items():
        totals.update(counts)
        cells = [str(counts.get(c, 0)) for c in classes]
        lines.append(f"| {name} | " + " | ".join(cells) + f" | {sum(counts.values())} |")
    cells = [str(totals.get(c, 0)) for c in classes]
    lines += ["| **total** | " + " | ".join(cells) + f" | {sum(totals.values())} |", ""]
    return lines


def to_markdown(stats: dict[str, Any], min_train: int) -> str:
    classes = stats["classes"]
    order = [s for s in (*SPLITS, "unassigned") if s in stats["by_split"]]
    lines = ["# Stroke dataset", ""]
    lines += _count_table("Samples per class and split", {s: stats["by_split"][s] for s in order},
                          classes)  # fmt: skip
    low = low_classes(stats, min_train)
    if low:
        lines += [f"**Fewer than {min_train} training samples:** " + ", ".join(low)
                  + " (use class weighting / augmentation).", ""]  # fmt: skip
    else:
        lines += [f"Every class has at least {min_train} training samples.", ""]
    lines += _count_table("Samples per player", stats["by_player"], classes)
    lines += ["## Excluded ShuttleSet types", "", "| Type | Count |", "| --- | ---: |"]
    lines += [f"| {t} | {n} |" for t, n in stats["excluded"].items()]
    lines += [f"| {t} (unknown type) | {n} |" for t, n in stats["unknown"].items()]
    lines += ["", "## Clip extraction", "",
              "| Match | Annotated | Clips | Not extracted | Missing files |",
              "| --- | ---: | ---: | ---: | ---: |"]  # fmt: skip
    for match_id, f in stats["extraction"].items():
        annotated = "n/a" if f["annotated"] is None else f["annotated"]
        not_extracted = "n/a" if f["not_extracted"] is None else f["not_extracted"]
        lines.append(f"| {match_id} | {annotated} | {f['indexed']} | {not_extracted} | "
                     f"{f['missing_files']} |")  # fmt: skip
    return "\n".join(lines) + "\n"


def write_report(stats: dict[str, Any], markdown: str, out_md: Path) -> None:
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(markdown, encoding="utf-8")
    out_md.with_suffix(".json").write_text(json.dumps(stats, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clips", type=Path, default=DATA_DIR / "clips")
    parser.add_argument("--splits", type=Path, default=BACKEND_DIR / "configs" / "splits.json")
    parser.add_argument("--shuttleset", type=Path, default=DATA_DIR / "shuttleset")
    parser.add_argument("--min-train", type=int, default=500)
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "dataset.md")
    args = parser.parse_args()

    splits = json.loads(args.splits.read_text(encoding="utf-8")) if args.splits.exists() else {}
    shuttleset = args.shuttleset if args.shuttleset.exists() else None
    stats = collect(args.clips, splits, shuttleset)
    if not stats["extraction"]:
        raise SystemExit(f"no index.csv files under {args.clips}; run extract_clips.py first")
    stats["min_train"] = args.min_train
    stats["low_classes"] = low_classes(stats, args.min_train)
    markdown = to_markdown(stats, args.min_train)
    print(markdown)
    write_report(stats, markdown, args.out)
    print(f"wrote {args.out} and {args.out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
