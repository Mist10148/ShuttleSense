"""Split ShuttleSet matches into train/val/test by match (task T3.4).

Usage: python scripts/make_splits.py [--sizes 31,6,7] [--seed 42]
Reads data/clips/<match_id>/index.csv, writes data/splits.json and configs/splits.json.
"""

from __future__ import annotations

import argparse
import csv
import json
import random
from collections import Counter
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BACKEND_DIR / "data"
SPLITS = ("train", "val", "test")


def make_splits(
    class_counts: dict[str, dict[str, int]],
    sizes: tuple[int, int, int] = (31, 6, 7),
    seed: int = 42,
) -> dict[str, list[str]]:
    """Greedy class-stratified split.

    Matches are visited in a seeded order, largest first; each goes to the split with room
    whose class distribution ends up closest to the overall one (L1 distance), weighted by
    how far that split still is from its target size.
    """
    matches = sorted(class_counts)
    if sum(sizes) != len(matches):
        total = len(matches)
        ratios = [s / sum(sizes) for s in sizes]
        sizes = (total - round(total * ratios[1]) - round(total * ratios[2]),
                 round(total * ratios[1]), round(total * ratios[2]))  # fmt: skip
    rng = random.Random(seed)
    rng.shuffle(matches)
    matches.sort(key=lambda m: -sum(class_counts[m].values()))
    overall = Counter()
    for counts in class_counts.values():
        overall.update(counts)
    classes = sorted(overall)
    total = sum(overall.values()) or 1
    target = {c: overall[c] / total for c in classes}

    splits: dict[str, list[str]] = {s: [] for s in SPLITS}
    totals = {s: Counter() for s in SPLITS}

    def distance(counts: Counter) -> float:
        n = sum(counts.values()) or 1
        return sum(abs(counts[c] / n - target[c]) for c in classes)

    for m in matches:
        best, best_score = None, None
        for s, size in zip(SPLITS, sizes, strict=True):
            if len(splits[s]) >= size:
                continue
            merged = totals[s] + Counter(class_counts[m])
            fill = len(splits[s]) / size
            score = distance(merged) + fill
            if best_score is None or score < best_score:
                best, best_score = s, score
        assert best is not None
        splits[best].append(m)
        totals[best].update(class_counts[m])
    return {s: sorted(splits[s]) for s in SPLITS}


def read_class_counts(clips_dir: Path) -> dict[str, dict[str, int]]:
    from shuttlesense.strokes.labels import map_label

    counts: dict[str, dict[str, int]] = {}
    for index in sorted(clips_dir.glob("*/index.csv")):
        c: Counter = Counter()
        with index.open(newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                label = map_label(row["shuttleset_type"])
                if label is not None:
                    c[label] += 1
        counts[index.parent.name] = dict(c)
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", default="31,6,7", help="train,val,test match counts")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--clips", type=Path, default=DATA_DIR / "clips")
    args = parser.parse_args()
    counts = read_class_counts(args.clips)
    if not counts:
        raise SystemExit(f"no index.csv files under {args.clips}; run extract_clips.py first")
    sizes = tuple(int(v) for v in args.sizes.split(","))
    result = {**make_splits(counts, sizes, args.seed), "seed": args.seed}
    text = json.dumps(result, indent=2) + "\n"
    for path in (DATA_DIR / "splits.json", BACKEND_DIR / "configs" / "splits.json"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    for s in SPLITS:
        print(f"{s:<5} {len(result[s]):>2} matches")


if __name__ == "__main__":
    main()
