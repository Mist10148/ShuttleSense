"""Train a stroke classifier: 1D CNN, LSTM or Random Forest (T3.8, T3.9, T11.4-T11.6).

Usage: python scripts/train_stroke_classifier.py [--algorithm cnn|lstm|rf] [--config FILE]
                [--pose-only] [--seed 42 | --seeds 1,2,3] [--epochs N]
                [--splits FILE | --train m01,m02 --val m03]

Without --config, configs/stroke_<algorithm>.yaml is used. Reads data/features/<id>.npz and
the split file (data.splits). For each seed, saves the best model on val macro-F1 to
<checkpoint>_seed<seed><ext>, and per-epoch + test metrics to <metrics>_seed<seed>.json
("_pose_only" before "_seed" for the ablation). The seed with the best val macro-F1 is also
copied to <checkpoint><ext>, the file the pipeline loads.

- cnn, lstm: a torch checkpoint {state_dict, kind, in_features, window_frames, classes,
  config, use_trajectory, pose_norm, temperature} and, when data.window_fps is set,
  window_fps. temperature is fitted on the val split after training (fit_temperature).
  train.shift_frames (2), train.noise (0.01) and train.label_smoothing (0) tune training;
  train.scale_jitter, train.keypoint_dropout and train.shuttle_dropout (all 0) add the
  augmentation steps of strokes/dataset.py.
- rf: scikit-learn trains the forest on summary features (strokes/rf.py); it is saved as
  plain arrays in an .npz file, which inference reads without scikit-learn.
  model.summary_version picks the summary rows; train.shift_copies adds shifted windows.

scripts/make_figures.py turns the metrics files into docs/results/strokes.md.
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
from pathlib import Path

import numpy as np

from shuttlesense.config import load_config

BACKEND_DIR = Path(__file__).resolve().parent.parent


def seed_everything(seed: int) -> None:
    import torch

    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def model_input(xb, kind: str):
    """Datasets yield (batch, features, time); the LSTM wants (batch, time, features)."""
    return xb.transpose(1, 2) if kind == "lstm" else xb


def predict_logits(model, dataset, batch_size: int, device: str, kind: str = "cnn") -> np.ndarray:
    import torch

    model.eval()
    out = []
    with torch.inference_mode():
        for start in range(0, len(dataset), batch_size):
            stop = min(start + batch_size, len(dataset))
            xb = np.stack([dataset[i][0] for i in range(start, stop)])
            logits = model(model_input(torch.from_numpy(xb).to(device), kind))
            out.append(logits.float().cpu().numpy())
    return np.concatenate(out) if out else np.zeros((0, 0), np.float32)


def predict(model, dataset, batch_size: int, device: str, kind: str = "cnn") -> np.ndarray:
    logits = predict_logits(model, dataset, batch_size, device, kind)
    return logits.argmax(axis=1) if len(logits) else np.zeros(0, int)


def nll(logits: np.ndarray, y: np.ndarray, temperature: float = 1.0) -> float:
    """Mean negative log-likelihood of the true classes at a softmax temperature."""
    z = logits / temperature
    z = z - z.max(axis=1, keepdims=True)
    log_probs = z - np.log(np.exp(z).sum(axis=1, keepdims=True))
    return float(-log_probs[np.arange(len(y)), y].mean())


def fit_temperature(logits: np.ndarray, y: np.ndarray) -> float:
    """The softmax temperature with the lowest NLL on (logits, y): one number, found on a
    grid from 0.5 to 5. It rescales confidences and leaves every predicted class as it is."""
    if not len(y):
        return 1.0
    grid = np.exp(np.linspace(np.log(0.5), np.log(5.0), 93))
    return round(float(grid[int(np.argmin([nll(logits, y, t) for t in grid]))]), 4)


def checkpoint_meta(cfg: dict, kind: str, train_ds, classes: list, use_trajectory: bool) -> dict:
    """What inference needs to rebuild the feature window a model was trained on."""
    meta = {
        "kind": kind,
        "in_features": train_ds.in_features,
        "window_frames": int(train_ds.x.shape[1]),
        "classes": classes,
        "use_trajectory": use_trajectory,
        "pose_norm": cfg["data"].get("pose_norm", "bbox_height"),
    }
    # The frame rate of the training windows; inference then covers the same time span on a
    # clip at another rate (strokes.features.build_window). Left out when the data has none.
    if cfg["data"].get("window_fps"):
        meta["window_fps"] = float(cfg["data"]["window_fps"])
    return meta


def train_rf(cfg: dict, splits: dict, *, use_trajectory: bool, seed: int) -> dict:
    """Fit a Random Forest on summary features; "checkpoint" is a strokes.rf.Forest."""
    try:
        from sklearn.ensemble import RandomForestClassifier
    except ImportError as exc:
        raise SystemExit("scikit-learn is needed to train the Random Forest") from exc

    from shuttlesense.strokes.dataset import StrokeDataset, shift_window
    from shuttlesense.strokes.features import flip_window
    from shuttlesense.strokes.metrics import classification_report
    from shuttlesense.strokes.rf import Forest, summary_features

    classes = list(cfg["data"]["classes"])
    features_dir = BACKEND_DIR / cfg["data"]["features_dir"]
    mcfg = cfg.get("model", {})
    train_ds = StrokeDataset(features_dir, splits["train"], use_trajectory)
    val_ds = StrokeDataset(features_dir, splits["val"], use_trajectory)
    if len(train_ds) == 0 or len(val_ds) == 0:
        raise SystemExit("empty train or val split: check data/features and the split file")
    x, y = train_ds.x, train_ds.y
    tcfg = cfg.get("train", {})
    version = int(mcfg.get("summary_version", 1))
    # Each copy is reduced to its summary rows at once: the windows of every copy together
    # would not fit in memory.
    rows = []
    for shift in [0, *tcfg.get("shift_copies", [])]:  # the hit a few frames early or late
        copy = x if not shift else np.stack([shift_window(w.copy(), int(shift)) for w in x])
        rows.append(summary_features(copy, version))
        if tcfg.get("flip_augment", True):  # mirrored copies, as the CNN sees
            mirrored = np.stack([flip_window(w, use_trajectory) for w in copy])
            rows.append(summary_features(mirrored, version))
    y = np.concatenate([y] * len(rows))
    rows = np.concatenate(rows)
    model = RandomForestClassifier(
        n_estimators=mcfg.get("trees", 200),
        max_depth=mcfg.get("max_depth", 18),
        min_samples_leaf=mcfg.get("min_samples_leaf", 3),
        max_features=mcfg.get("max_features", "sqrt"),
        class_weight="balanced_subsample" if mcfg.get("class_weighting", True) else None,
        n_jobs=-1,
        random_state=seed,
    )
    model.fit(rows, y)
    meta = checkpoint_meta(cfg, "rf", train_ds, classes, use_trajectory)
    if version != 1:
        meta["summary_version"] = version
    meta["config"] = {"model": mcfg}
    forest = Forest.from_sklearn(model, meta)
    val_pred = forest.predict_proba(summary_features(val_ds.x, version)).argmax(1)
    val = classification_report(val_ds.y, val_pred, classes)
    print(json.dumps({"val_macro_f1": val["macro_f1"], "val_accuracy": val["accuracy"]}))
    result: dict = {
        "seed": seed,
        "algorithm": "rf",
        "use_trajectory": use_trajectory,
        "history": [],
        "best_val_macro_f1": val["macro_f1"],
    }
    if splits.get("test"):
        test_ds = StrokeDataset(features_dir, splits["test"], use_trajectory)
        if len(test_ds):
            preds = forest.predict_proba(summary_features(test_ds.x, version)).argmax(1)
            result["test"] = classification_report(test_ds.y, preds, classes)
    result["checkpoint"] = forest
    return result


def train(
    cfg: dict,
    splits: dict,
    *,
    use_trajectory: bool,
    seed: int,
    device: str,
    kind: str | None = None,
) -> dict:
    """Train with early stopping on val macro-F1; returns metrics plus a "checkpoint".

    kind is "cnn", "lstm" or "rf" (default: the config's `algorithm`, else "cnn").
    """
    kind = kind or cfg.get("algorithm", "cnn")
    if kind == "rf":
        return train_rf(cfg, splits, use_trajectory=use_trajectory, seed=seed)
    import torch
    from torch.utils.data import DataLoader

    from shuttlesense.strokes.dataset import StrokeDataset
    from shuttlesense.strokes.metrics import classification_report
    from shuttlesense.strokes.model import build_from_config

    classes = list(cfg["data"]["classes"])
    features_dir = BACKEND_DIR / cfg["data"]["features_dir"]
    tcfg = cfg["train"]
    seed_everything(seed)
    train_ds = StrokeDataset(
        features_dir,
        splits["train"],
        use_trajectory,
        augment_data=True,
        seed=seed,
        max_shift=int(tcfg.get("shift_frames", 2)),
        noise=float(tcfg.get("noise", 0.01)),
        scale_jitter=float(tcfg.get("scale_jitter", 0.0)),
        keypoint_dropout=float(tcfg.get("keypoint_dropout", 0.0)),
        shuttle_dropout=float(tcfg.get("shuttle_dropout", 0.0)),
    )
    val_ds = StrokeDataset(features_dir, splits["val"], use_trajectory)
    if len(train_ds) == 0 or len(val_ds) == 0:
        raise SystemExit("empty train or val split: check data/features and the split file")

    model = build_from_config(train_ds.in_features, cfg.get("model", {}), len(classes), kind)
    model = model.to(device)
    weights = None
    if tcfg.get("class_weighting") == "inverse_frequency":
        weights = torch.from_numpy(train_ds.class_weights(len(classes))).to(device)
    loss_fn = torch.nn.CrossEntropyLoss(
        weight=weights, label_smoothing=float(tcfg.get("label_smoothing", 0.0))
    )
    opt = torch.optim.AdamW(model.parameters(), lr=tcfg["lr"], weight_decay=tcfg["weight_decay"])
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=tcfg["epochs"])
    loader = DataLoader(
        train_ds,
        batch_size=tcfg["batch_size"],
        shuffle=True,
        generator=torch.Generator().manual_seed(seed),
    )

    history, best_f1, best_state, patience = [], -1.0, None, 0
    for epoch in range(1, tcfg["epochs"] + 1):
        model.train()
        total = 0.0
        for xb, yb in loader:
            xb, yb = xb.to(device), yb.to(device)
            opt.zero_grad()
            loss = loss_fn(model(model_input(xb, kind)), yb)
            loss.backward()
            if tcfg.get("grad_clip"):
                torch.nn.utils.clip_grad_norm_(model.parameters(), tcfg["grad_clip"])
            opt.step()
            total += float(loss.detach()) * len(yb)
        sched.step()
        val = classification_report(val_ds.y, predict(model, val_ds, 512, device, kind), classes)
        row = {
            "epoch": epoch,
            "loss": total / len(train_ds),
            "val_macro_f1": val["macro_f1"],
            "val_accuracy": val["accuracy"],
        }
        history.append(row)
        print(json.dumps(row))
        if val["macro_f1"] > best_f1:
            best_f1, patience = val["macro_f1"], 0
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
        else:
            patience += 1
            if patience >= tcfg.get("early_stopping_patience", 8):
                break

    model.load_state_dict(best_state)
    val_logits = predict_logits(model, val_ds, 512, device, kind)
    temperature = fit_temperature(val_logits, val_ds.y)
    result: dict = {
        "seed": seed,
        "algorithm": kind,
        "use_trajectory": use_trajectory,
        "history": history,
        "best_val_macro_f1": best_f1,
        "temperature": temperature,
        "val_nll": {
            "raw": nll(val_logits, val_ds.y),
            "scaled": nll(val_logits, val_ds.y, temperature),
        },
    }
    if splits.get("test"):
        test_ds = StrokeDataset(features_dir, splits["test"], use_trajectory)
        if len(test_ds):
            preds = predict(model, test_ds, 512, device, kind)
            result["test"] = classification_report(test_ds.y, preds, classes)
    result["checkpoint"] = {
        "state_dict": best_state,
        "config": cfg,
        "temperature": temperature,
        **checkpoint_meta(cfg, kind, train_ds, classes, use_trajectory),
    }
    return result


def save_checkpoint(checkpoint, path: Path) -> None:
    """A torch dict goes through torch.save; a Forest writes its own .npz."""
    if hasattr(checkpoint, "save"):
        checkpoint.save(path)
        return
    import torch

    torch.save(checkpoint, path)


def _ids(text: str | None) -> list[str]:
    return [m for m in (text or "").split(",") if m]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--algorithm", choices=["cnn", "lstm", "rf"], default=None)
    parser.add_argument("--config", type=Path, default=None, help="default: stroke_<algo>.yaml")
    parser.add_argument("--splits", type=Path, help="split file (overrides data.splits)")
    parser.add_argument("--pose-only", action="store_true", help="ablation: drop shuttle features")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--seeds", help="comma-separated seeds, one run each (T3.9: 3 seeds)")
    parser.add_argument("--epochs", type=int, default=None)
    parser.add_argument("--train", help="comma-separated match ids (overrides the split file)")
    parser.add_argument("--val", help="comma-separated match ids")
    parser.add_argument("--test", help="comma-separated match ids")
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    args = parser.parse_args()

    config_path = args.config
    if config_path is None:
        config_path = BACKEND_DIR / "configs" / f"stroke_{args.algorithm or 'cnn'}.yaml"
    cfg = load_config(config_path)
    kind = args.algorithm or cfg.get("algorithm", "cnn")
    cfg["algorithm"] = kind
    if args.epochs:
        cfg.setdefault("train", {})["epochs"] = args.epochs
    if args.train:
        splits = {"train": _ids(args.train), "val": _ids(args.val), "test": _ids(args.test)}
    else:
        split_file = args.splits or BACKEND_DIR / cfg["data"]["splits"]
        splits = json.loads(Path(split_file).read_text(encoding="utf-8"))
    use_trajectory = cfg["data"].get("use_trajectory", True) and not args.pose_only
    if args.seeds:
        seeds = [int(s) for s in args.seeds.split(",") if s]
    else:
        seeds = [args.seed if args.seed is not None else cfg.get("seed", 42)]
    device = "cpu"
    if kind != "rf":
        from shuttlesense.config import detect_device

        device = detect_device(args.device)
    suffix = "" if use_trajectory else "_pose_only"
    ckpt_base = BACKEND_DIR / cfg["output"]["checkpoint"]
    metrics_base = BACKEND_DIR / cfg["output"]["metrics"]
    best_f1, best_ckpt = -1.0, None
    for seed in seeds:
        result = train(
            cfg, splits, use_trajectory=use_trajectory, seed=seed, device=device, kind=kind
        )
        ckpt = output_path(ckpt_base, suffix, seed)
        ckpt.parent.mkdir(parents=True, exist_ok=True)
        save_checkpoint(result.pop("checkpoint"), ckpt)
        metrics = output_path(metrics_base, suffix, seed)
        metrics.parent.mkdir(parents=True, exist_ok=True)
        metrics.write_text(json.dumps(result, indent=2), encoding="utf-8")
        test = result.get("test", {})
        acc = test.get("macro_accuracy", float("nan"))
        print(f"seed {seed}: saved {ckpt.name}; test macro accuracy {acc:.3f}")
        if result["best_val_macro_f1"] > best_f1:
            best_f1, best_ckpt = result["best_val_macro_f1"], ckpt
    if best_ckpt is not None:
        default = output_path(ckpt_base, suffix, None)
        shutil.copyfile(best_ckpt, default)
        print(f"{default.name} <- {best_ckpt.name} (best val macro-F1 {best_f1:.3f})")


def output_path(base: Path, suffix: str, seed: int | None) -> Path:
    """<stem><suffix>_seed<seed><ext>, or <stem><suffix><ext> without a seed."""
    tag = "" if seed is None else f"_seed{seed}"
    return base.with_name(f"{base.stem}{suffix}{tag}{base.suffix}")


if __name__ == "__main__":
    main()
