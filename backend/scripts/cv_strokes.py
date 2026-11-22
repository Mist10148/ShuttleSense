"""Match-grouped cross-validation for the stroke models (D41).

Usage:
    python scripts/cv_strokes.py --algorithm cnn|lstm|rf [--config FILE] [--folds 5]
        [--set train.loss=logit_adjusted --set data.feature_version=2 ...]
        [--tta] [--epochs N] [--name TAG] [--max-folds K]

The BST test split has been read three times (docs/EVALUATION.md), so choices between
training options are made here instead: train + val are pooled and split into `--folds`
folds by match, so no match is in both the training and the scored part of a fold. Inside
each fold one more slice of matches (about a tenth) is held out for early stopping and the
temperature, so the scored matches are never seen while training.

Writes outputs/cv/<name>.json (the mean and spread over folds of accuracy, macro accuracy,
macro-F1, expected calibration error, per-class F1 and the drop -> smash confusion) and
outputs/cv/<name>_oof.npz (the out-of-fold probabilities of every window, with y and the
match of each), which scripts/fit_stroke_ensemble.py uses to weigh the ensemble.
"""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
import time
from pathlib import Path

import numpy as np

BACKEND_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(BACKEND_DIR / "scripts"))

from train_stroke_classifier import train  # noqa: E402

from shuttlesense.config import load_config  # noqa: E402


def match_of(meta: str) -> str:
    """The BST match id of a window: 'Bottom_<type>/11_1_16_4' -> '11'."""
    clip = meta.split("/", 1)[-1]
    return re.split(r"[_/]", clip)[0]


def load_pool(features_dir: Path, names: list[str]) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    xs, ys, groups = [], [], []
    for name in names:
        with np.load(features_dir / f"{name}.npz") as data:
            xs.append(data["X"].astype(np.float32))
            ys.append(data["y"].astype(np.int64))
            groups.append(np.array([match_of(str(m)) for m in data["meta"]]))
    return np.concatenate(xs), np.concatenate(ys), np.concatenate(groups)


def group_folds(groups: np.ndarray, folds: int, seed: int) -> list[np.ndarray]:
    """Fold index of every window: matches shuffled, then dealt out to balance window counts."""
    rng = np.random.default_rng(seed)
    matches = np.unique(groups)
    rng.shuffle(matches)
    sizes = {m: int((groups == m).sum()) for m in matches}
    load = np.zeros(folds, int)
    assign: dict[str, int] = {}
    for m in sorted(matches, key=lambda m: -sizes[m]):
        k = int(np.argmin(load))
        assign[m] = k
        load[k] += sizes[m]
    fold = np.array([assign[g] for g in groups])
    return [np.flatnonzero(fold == k) for k in range(folds)]


def inner_split(groups: np.ndarray, idx: np.ndarray, seed: int, share: float = 0.1):
    """(train, early-stop) indices from idx, holding out about `share` of its matches."""
    rng = np.random.default_rng(seed)
    matches = np.unique(groups[idx])
    rng.shuffle(matches)
    held = set(matches[: max(1, round(len(matches) * share))])
    mask = np.array([g in held for g in groups[idx]])
    return idx[~mask], idx[mask]


def ece(probs: np.ndarray, y: np.ndarray, bins: int = 15) -> float:
    """Expected calibration error of the top-class confidence."""
    conf = probs.max(1)
    right = probs.argmax(1) == y
    edges = np.linspace(0, 1, bins + 1)
    total = 0.0
    for lo, hi in zip(edges[:-1], edges[1:], strict=True):
        sel = (conf > lo) & (conf <= hi)
        if sel.any():
            total += sel.mean() * abs(conf[sel].mean() - right[sel].mean())
    return float(total)


def fold_probabilities(checkpoint, kind: str, x: np.ndarray, device: str, tta: bool):
    """[N, classes] probabilities of a just-trained model, as the pipeline computes them."""
    from shuttlesense.strokes.classify import predict_proba, tta_windows

    if kind == "rf":
        model, meta = checkpoint, checkpoint.meta
    else:
        from shuttlesense.strokes.model import build_from_config

        meta = checkpoint
        model = build_from_config(
            meta["in_features"], meta["config"].get("model", {}), len(meta["classes"]), kind
        )
        model.load_state_dict(meta["state_dict"])
        model.to(device).eval()
    views = tta_windows(x, bool(meta.get("use_trajectory", True)), tta, [-1, 1] if tta else [])
    version = int(meta.get("feature_version", 1))
    temperature = float(meta.get("temperature", 1.0)) if kind != "rf" else 1.0
    out = []
    for v in views:
        parts = []
        for start in range(0, len(v), 1024):
            parts.append(
                predict_proba(
                    model,
                    kind,
                    v[start : start + 1024],
                    device,
                    temperature,
                    feature_version=version,
                )
            )
        out.append(np.concatenate(parts))
    return np.mean(out, axis=0)


def apply_overrides(cfg: dict, pairs: list[str]) -> dict:
    """`--set a.b=value` (value parsed as YAML) into a copy of cfg."""
    import yaml

    cfg = copy.deepcopy(cfg)
    for pair in pairs:
        key, _, raw = pair.partition("=")
        node = cfg
        parts = key.split(".")
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        node[parts[-1]] = yaml.safe_load(raw)
    return cfg


def summarise(rows: list[dict], classes: list[str]) -> dict:
    def stat(key: str) -> dict:
        values = np.array([r[key] for r in rows])
        return {"mean": float(values.mean()), "std": float(values.std())}

    out = {
        k: stat(k)
        for k in (
            "accuracy",
            "macro_accuracy",
            "macro_f1",
            "macro_f1_plain",
            "ece",
            "drop_as_smash",
        )
    }
    out["per_class_f1"] = {
        c: float(np.mean([r["per_class"][c]["f1"] for r in rows])) for c in classes
    }
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--algorithm", choices=["cnn", "lstm", "rf"], required=True)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--folds", type=int, default=5)
    parser.add_argument("--max-folds", type=int, default=None, help="run only the first K")
    parser.add_argument("--set", action="append", default=[], help="config override a.b=v")
    parser.add_argument("--tta", action="store_true", help="score with test-time augmentation")
    parser.add_argument("--epochs", type=int)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--name", help="output tag (default: algorithm and overrides)")
    parser.add_argument("--device", choices=["cpu", "cuda"])
    args = parser.parse_args()

    from shuttlesense.config import detect_device
    from shuttlesense.strokes.metrics import classification_report

    config = args.config or BACKEND_DIR / "configs" / f"stroke_{args.algorithm}.yaml"
    cfg = apply_overrides(load_config(config), args.set)
    cfg["algorithm"] = args.algorithm
    if args.epochs:
        cfg["train"]["epochs"] = args.epochs
    classes = list(cfg["data"]["classes"])
    features_dir = BACKEND_DIR / cfg["data"]["features_dir"]
    x, y, groups = load_pool(features_dir, ["bst_train", "bst_val"])
    use_traj = cfg["data"].get("use_trajectory", True)
    if not use_traj:
        from shuttlesense.strokes.features import POSE_FEATURES

        x = x[:, :, :POSE_FEATURES]
    device = "cpu" if args.algorithm == "rf" else detect_device(args.device)
    folds = group_folds(groups, args.folds, args.seed)
    name = args.name or "_".join([args.algorithm, *[s.replace("=", "-") for s in args.set]])
    name += "_tta" if args.tta else ""
    out_dir = BACKEND_DIR / "outputs" / "cv"
    out_dir.mkdir(parents=True, exist_ok=True)

    oof = np.full((len(y), len(classes)), np.nan, np.float32)
    rows = []
    drop, smash = classes.index("drop"), classes.index("smash")
    for k, test_idx in enumerate(folds[: args.max_folds or args.folds]):
        started = time.time()
        rest = np.concatenate([f for j, f in enumerate(folds) if j != k])
        tr, es = inner_split(groups, rest, args.seed + k)
        splits = {
            "train": [],
            "val": [],
            "arrays": {"train": (x[tr], y[tr]), "val": (x[es], y[es])},
        }
        result = train(cfg, splits, use_trajectory=use_traj, seed=args.seed, device=device)
        probs = fold_probabilities(
            result["checkpoint"], args.algorithm, x[test_idx], device, args.tta
        )
        oof[test_idx] = probs
        report = classification_report(y[test_idx], probs.argmax(1), classes)
        cm = np.array(report["confusion_matrix"])
        report["ece"] = ece(probs, y[test_idx])
        plain = probs
        if args.tta:  # the same model scored on the windows as they are
            plain = fold_probabilities(
                result["checkpoint"], args.algorithm, x[test_idx], device, False
            )
        report["macro_f1_plain"] = classification_report(y[test_idx], plain.argmax(1), classes)[
            "macro_f1"
        ]
        report["drop_as_smash"] = float(cm[drop, smash] / max(cm[drop].sum(), 1))
        rows.append(report)
        print(
            json.dumps(
                {
                    "fold": k,
                    "macro_f1": round(report["macro_f1"], 4),
                    "accuracy": round(report["accuracy"], 4),
                    "ece": round(report["ece"], 4),
                    "seconds": round(time.time() - started),
                }
            ),
            flush=True,
        )
    summary = {
        "name": name,
        "algorithm": args.algorithm,
        "overrides": args.set,
        "tta": args.tta,
        "folds": len(rows),
        "windows": int(sum(len(folds[k]) for k in range(len(rows)))),
        **summarise(rows, classes),
    }
    (out_dir / f"{name}.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    np.savez_compressed(out_dir / f"{name}_oof.npz", probs=oof, y=y, groups=groups)
    print(json.dumps({k: summary[k] for k in ("name", "macro_f1", "accuracy", "ece")}))


if __name__ == "__main__":
    main()
