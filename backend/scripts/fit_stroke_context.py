"""Fit and measure the stroke context tables (strokes/context.py) from ShuttleSet.

Usage: python scripts/fit_stroke_context.py [--data data/shuttleset] [--features data/features]
                [--out shuttlesense/strokes/context_table.json] [--report docs/results/...]
                [--no-write]

ShuttleSet annotates every stroke of 45 singles matches with its type, its frame, and the
court area the player stood in. From the training matches this counts, per stroke class:

- how often it is the first stroke of a rally (only serves are);
- the time until the opponent's next stroke, in bins;
- how often the hitter, and the opponent at the reply, stood in the front or the rear zone.

Those likelihoods go to context_table.json. The script then measures what the context adds
to each of the three stroke models: the BST feature files (scripts/import_bst_features.py)
name each sample's match, set, rally and stroke number, so every validation and test window
is joined to its ShuttleSet row. The weight on the context is chosen on the validation
matches; the test matches are only used for the reported numbers.

The annotated hit frames stand in for the hit detector here, so this is the effect on
broadcast footage with perfect hits, not on phone footage (docs/results/strokes.md).
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np

from shuttlesense.schema import STROKE_CLASSES
from shuttlesense.strokes import context
from shuttlesense.strokes.labels import map_label

BACKEND_DIR = Path(__file__).resolve().parent.parent
CLASSES = list(STROKE_CLASSES)
# ShuttleSet player areas: the front row and the back row of a half court. The middle row
# (5, 6, 8) and the areas outside the court are neither.
FRONT_AREAS, REAR_AREAS = {"1", "2", "7"}, {"3", "4", "9"}
FLIGHT_EDGES_S = [0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 1.8]
SMOOTHING = 1.0  # add-one counts, so an unseen combination is unlikely, not impossible
# Matches 1 to 20 were recorded at 25 fps, the rest at 30 (BST README; checked below).
SLOW_MATCHES, SLOW_FPS, FAST_FPS = range(1, 21), 25.0, 30.0


def match_fps(match: int) -> float:
    return SLOW_FPS if match in SLOW_MATCHES else FAST_FPS


def area_zone(area: str) -> str | None:
    area = area.split(".")[0]
    if area in FRONT_AREAS:
        return "front"
    return "rear" if area in REAR_AREAS else None


def load_strokes(data: Path) -> dict[tuple[int, int, int, int], dict]:
    """(match, set, rally, stroke number) -> {label, evidence} for every annotated stroke."""
    out: dict[tuple[int, int, int, int], dict] = {}
    for path in sorted(data.glob("m*/set*.csv")):
        match, game = int(path.parent.name[1:]), int(path.stem[3:])
        fps = match_fps(match)
        with path.open(encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        for i, row in enumerate(rows):
            try:
                rally, number = int(float(row["rally"])), int(float(row["ball_round"]))
            except ValueError:
                continue
            try:
                label = map_label(row["type"])
            except KeyError:
                label = None
            nxt = (
                rows[i + 1] if i + 1 < len(rows) and rows[i + 1]["rally"] == row["rally"] else None
            )
            flight = receiver = None
            if nxt is not None and nxt["player"] != row["player"]:
                try:
                    seconds = (float(nxt["frame_num"]) - float(row["frame_num"])) / fps
                except ValueError:
                    seconds = None
                if seconds is not None and 0 < seconds <= context.DEFAULTS["max_flight_s"]:
                    flight, receiver = seconds, area_zone(nxt["player_location_area"])
            out[(match, game, rally, number)] = {
                "label": label,
                "evidence": context.Evidence(
                    first_in_rally=number == 1,
                    flight_s=flight,
                    hitter_zone=area_zone(row["player_location_area"]),
                    receiver_zone=receiver,
                ),
            }
    return out


def fit_table(strokes: dict, matches: set[int]) -> dict:
    """P(evidence | class) from the strokes of `matches`."""
    position = {c: Counter() for c in CLASSES}
    flight = {c: np.zeros(len(FLIGHT_EDGES_S) + 1) for c in CLASSES}
    zones = {name: {c: Counter() for c in CLASSES} for name in ("hitter_zone", "receiver_zone")}
    for (match, *_), s in strokes.items():
        c, e = s["label"], s["evidence"]
        if match not in matches or c is None:
            continue
        position[c]["first" if e.first_in_rally else "later"] += 1
        if e.flight_s is not None:
            flight[c][int(np.searchsorted(FLIGHT_EDGES_S, e.flight_s, side="right"))] += 1
            zones["receiver_zone"][c][e.receiver_zone or "mid"] += 1
        zones["hitter_zone"][c][e.hitter_zone or "mid"] += 1

    def share(counter: Counter, key: str, options: int) -> float:
        return round((counter[key] + SMOOTHING) / (sum(counter.values()) + SMOOTHING * options), 5)

    return {
        "source": "ShuttleSet stroke annotations, training matches (fit_stroke_context.py)",
        "matches": sorted(matches),
        "classes": CLASSES,
        "rally_position": {
            k: {c: share(position[c], k, 2) for c in CLASSES} for k in ("first", "later")
        },
        "flight_edges_s": FLIGHT_EDGES_S,
        "flight": {
            c: [round(float(v), 5) for v in (flight[c] + SMOOTHING) / (flight[c] + SMOOTHING).sum()]
            for c in CLASSES
        },
        **{
            name: {z: {c: share(zones[name][c], z, 3) for c in CLASSES} for z in ("front", "rear")}
            for name in zones
        },
    }


def model_probs(split: Path, device: str = "cpu") -> dict[str, np.ndarray]:
    """[N, classes] probabilities of each installed stroke model on a feature file."""
    from shuttlesense.strokes import registry
    from shuttlesense.strokes.classify import load_classifier, predict_proba

    x = np.load(split)["X"]
    out = {}
    for name in registry.ALGORITHMS:
        try:
            model, ckpt = load_classifier(registry.DEFAULT_WEIGHTS[name], device)
        except Exception as exc:  # weights or torch missing: report the others
            print(f"  {name}: skipped ({exc})")
            continue
        assert list(ckpt.get("classes", CLASSES)) == CLASSES
        parts = [
            predict_proba(
                model,
                ckpt.get("kind", "cnn"),
                x[i : i + 512],
                device,
                float(ckpt.get("temperature", 1.0)),
            )  # fmt: skip
            for i in range(0, len(x), 512)
        ]
        out[name] = np.concatenate(parts)
    return out


def join(split: Path, strokes: dict) -> tuple[np.ndarray, list[context.Evidence | None]]:
    """(labels, evidence per sample); meta is "<Top|Bottom>_<type>/<match>_<set>_<rally>_<n>"."""
    data = np.load(split)
    evidence: list[context.Evidence | None] = []
    for meta, y in zip(data["meta"], data["y"], strict=True):
        key = tuple(int(v) for v in str(meta).split("/")[1].split("_")[:4])
        s = strokes.get(key)
        # A sample whose annotation row says another class was matched to the wrong row.
        ok = s is not None and s["label"] == CLASSES[int(y)]
        evidence.append(s["evidence"] if ok else None)
    return data["y"], evidence


def scores(probs: np.ndarray, y: np.ndarray) -> tuple[float, float, np.ndarray]:
    """(accuracy, macro accuracy = mean per-class recall, confusion [true, predicted])."""
    pred = probs.argmax(axis=1)
    conf = np.zeros((len(CLASSES), len(CLASSES)), dtype=int)
    np.add.at(conf, (y, pred), 1)
    recall = conf.diagonal() / np.maximum(conf.sum(axis=1), 1)
    return float((pred == y).mean()), float(recall.mean()), conf


def with_context(probs, evidence, table, weight, floor, *, use=None) -> np.ndarray:
    """`use` keeps only some evidence fields (ablation); None keeps all."""
    out = probs.copy()
    for i, e in enumerate(evidence):
        if e is None:
            continue
        if use is not None:
            e = context.Evidence(**{k: getattr(e, k) for k in use})
        out[i] = context.apply(probs[i], e, table, CLASSES, weight, floor)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--data", type=Path, default=BACKEND_DIR / "data/shuttleset")
    parser.add_argument("--features", type=Path, default=BACKEND_DIR / "data/features")
    parser.add_argument("--out", type=Path, default=context.TABLE_PATH)
    parser.add_argument("--report", type=Path, default=None, help="write the results as JSON")
    parser.add_argument("--no-write", action="store_true", help="measure only")
    args = parser.parse_args()

    strokes = load_strokes(args.data)
    split_matches = {}
    for name in ("train", "val", "test"):
        meta = np.load(args.features / f"bst_{name}.npz")["meta"]
        split_matches[name] = {int(str(m).split("/")[1].split("_")[0]) for m in meta}
    assert not split_matches["train"] & (split_matches["val"] | split_matches["test"])
    table = fit_table(strokes, split_matches["train"])
    print(f"table from {len(table['matches'])} training matches")

    report: dict = {"splits": {k: sorted(v) for k, v in split_matches.items()}, "models": {}}
    val_y, val_e = join(args.features / "bst_val.npz", strokes)
    test_y, test_e = join(args.features / "bst_test.npz", strokes)
    for name, e in (("val", val_e), ("test", test_e)):
        joined = sum(x is not None for x in e)
        print(f"{name}: {joined}/{len(e)} samples joined to an annotation row")
        report[f"{name}_joined"] = [joined, len(e)]
    val_p, test_p = (
        model_probs(args.features / "bst_val.npz"),
        model_probs(args.features / "bst_test.npz"),
    )

    # One weight and floor for all three models, chosen on the validation matches.
    grid = [(w, f) for w in (0.3, 0.5, 0.7, 1.0) for f in (0.005, 0.02, 0.05)]
    mean_macro = {
        (w, f): np.mean(
            [scores(with_context(p, val_e, table, w, f), val_y)[1] for p in val_p.values()]
        )
        for w, f in grid
    }
    weight, floor = max(mean_macro, key=mean_macro.get)
    print(f"chosen on validation: weight {weight}, floor {floor}")
    report["weight"], report["floor"] = weight, floor

    ablations = {
        "rally position only": ("first_in_rally",),
        "flight time only": ("flight_s",),
        "zones only": ("hitter_zone", "receiver_zone"),
    }
    for name, probs in test_p.items():
        acc0, macro0, conf0 = scores(probs, test_y)
        acc1, macro1, conf1 = scores(with_context(probs, test_e, table, weight, floor), test_y)
        row = {"model_only": [acc0, macro0], "with_context": [acc1, macro1], "ablation": {}}
        print(f"\n{name}: accuracy {acc0:.4f} -> {acc1:.4f}, macro {macro0:.4f} -> {macro1:.4f}")
        for label, use in ablations.items():
            _, m, _ = scores(with_context(probs, test_e, table, weight, floor, use=use), test_y)
            row["ablation"][label] = m
            print(f"  {label}: macro {m:.4f}")
        recall0 = conf0.diagonal() / np.maximum(conf0.sum(axis=1), 1)
        recall1 = conf1.diagonal() / np.maximum(conf1.sum(axis=1), 1)
        row["recall"] = {
            c: [float(a), float(b)] for c, a, b in zip(CLASSES, recall0, recall1, strict=True)
        }
        for c, a, b in zip(CLASSES, recall0, recall1, strict=True):
            print(f"  {c:9s} recall {a:.3f} -> {b:.3f}")
        pairs = defaultdict(list)
        for t, p in (("drop", "smash"), ("smash", "drop"), ("lift", "net_shot"),
                     ("net_shot", "lift"), ("clear", "lift"), ("clear", "drop")):  # fmt: skip
            i, j = CLASSES.index(t), CLASSES.index(p)
            pairs[f"{t} called {p}"] = [int(conf0[i, j]), int(conf1[i, j])]
            print(f"  {t} called {p}: {conf0[i, j]} -> {conf1[i, j]}")
        row["confusions"] = dict(pairs)
        report["models"][name] = row

    if not args.no_write:
        table["weight"], table["floor"] = weight, floor
        args.out.write_text(json.dumps(table, indent=1) + "\n", encoding="utf-8")
        print(f"\nwrote {args.out}")
    if args.report:
        args.report.write_text(json.dumps(report, indent=1) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
