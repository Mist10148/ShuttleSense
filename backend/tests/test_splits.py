from __future__ import annotations

import importlib.util
import random
from collections import Counter
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


@pytest.fixture()
def splits_module():
    spec = importlib.util.spec_from_file_location("make_splits", SCRIPTS / "make_splits.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fake_counts(n: int = 44) -> dict[str, dict[str, int]]:
    rng = random.Random(0)
    classes = ["smash", "clear", "drop", "net_shot", "lift", "serve"]
    return {f"m{i:02d}": {c: rng.randint(20, 120) for c in classes} for i in range(n)}


def test_no_match_in_two_splits(splits_module) -> None:
    counts = fake_counts()
    splits = splits_module.make_splits(counts)
    all_ids = splits["train"] + splits["val"] + splits["test"]
    assert sorted(all_ids) == sorted(counts) and len(set(all_ids)) == 44
    assert [len(splits[s]) for s in ("train", "val", "test")] == [31, 6, 7]


def test_split_is_deterministic(splits_module) -> None:
    counts = fake_counts()
    assert splits_module.make_splits(counts, seed=42) == splits_module.make_splits(counts, seed=42)


def test_class_proportions_close_to_overall(splits_module) -> None:
    counts = fake_counts()
    splits = splits_module.make_splits(counts)
    overall = Counter()
    for c in counts.values():
        overall.update(c)
    for ids in splits.values():
        part = Counter()
        for m in ids:
            part.update(counts[m])
        for cls in overall:
            share = part[cls] / sum(part.values()) - overall[cls] / sum(overall.values())
            assert abs(share) <= 0.05
