"""Train the 1D CNN stroke classifier (T3.8, T3.9).

Usage: python scripts/train_stroke_classifier.py --config configs/stroke_cnn.yaml
                [--pose-only] [--seed 42] [--epochs N] [--train m01,m02 --val m03]

Reads data/features/<match_id>.npz and the match split (data.splits). Saves the best
checkpoint on val macro-F1 as {state_dict, in_features, window_frames, classes, config,
use_trajectory}
and per-epoch + test metrics as JSON.
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

import numpy as np

from shuttlesense.config import load_config

BACKEND_DIR = Path(__file__).resolve().parent.parent


def seed_everything(seed: int) -> None:
    import torch

    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def predict(model, dataset, batch_size: int, device: str) -> np.ndarray:
    import torch

    model.eval()
    preds = []
    with torch.inference_mode():
        for start in range(0, len(dataset), batch_size):
            stop = min(start + batch_size, len(dataset))
            xb = np.stack([dataset[i][0] for i in range(start, stop)])
            logits = model(torch.from_numpy(xb).to(device))
            preds.append(logits.argmax(dim=1).cpu().numpy())
    return np.concatenate(preds) if preds else np.zeros(0, int)


def train(cfg: dict, splits: dict, *, use_trajectory: bool, seed: int, device: str) -> dict:
    """Train with early stopping on val macro-F1; returns metrics plus a "checkpoint" dict."""
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
        features_dir, splits["train"], use_trajectory, augment_data=True, seed=seed
    )
    val_ds = StrokeDataset(features_dir, splits["val"], use_trajectory)
    if len(train_ds) == 0 or len(val_ds) == 0:
        raise SystemExit("empty train or val split: check data/features and the split file")

    model = build_from_config(train_ds.in_features, cfg.get("model", {}), len(classes))
    model = model.to(device)
    weights = None
    if tcfg.get("class_weighting") == "inverse_frequency":
        weights = torch.from_numpy(train_ds.class_weights(len(classes))).to(device)
    loss_fn = torch.nn.CrossEntropyLoss(weight=weights)
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
            loss = loss_fn(model(xb), yb)
            loss.backward()
            opt.step()
            total += float(loss.detach()) * len(yb)
        sched.step()
        val = classification_report(val_ds.y, predict(model, val_ds, 512, device), classes)
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
    result: dict = {
        "seed": seed,
        "use_trajectory": use_trajectory,
        "history": history,
        "best_val_macro_f1": best_f1,
    }
    if splits.get("test"):
        test_ds = StrokeDataset(features_dir, splits["test"], use_trajectory)
        if len(test_ds):
            preds = predict(model, test_ds, 512, device)
            result["test"] = classification_report(test_ds.y, preds, classes)
    result["checkpoint"] = {
        "state_dict": best_state,
        "in_features": train_ds.in_features,
        "window_frames": int(train_ds.x.shape[1]),
        "classes": classes,
        "config": cfg,
        "use_trajectory": use_trajectory,
    }
    return result


def _ids(text: str | None) -> list[str]:
    return [m for m in (text or "").split(",") if m]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=BACKEND_DIR / "configs" / "stroke_cnn.yaml")
    parser.add_argument("--pose-only", action="store_true", help="ablation: drop shuttle features")
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--epochs", type=int, default=None)
    parser.add_argument("--train", help="comma-separated match ids (overrides the split file)")
    parser.add_argument("--val", help="comma-separated match ids")
    parser.add_argument("--test", help="comma-separated match ids")
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    args = parser.parse_args()

    import torch

    from shuttlesense.config import detect_device

    cfg = load_config(args.config)
    if args.epochs:
        cfg["train"]["epochs"] = args.epochs
    if args.train:
        splits = {"train": _ids(args.train), "val": _ids(args.val), "test": _ids(args.test)}
    else:
        splits = json.loads((BACKEND_DIR / cfg["data"]["splits"]).read_text(encoding="utf-8"))
    use_trajectory = cfg["data"].get("use_trajectory", True) and not args.pose_only
    seed = args.seed if args.seed is not None else cfg.get("seed", 42)
    device = detect_device(args.device)
    result = train(cfg, splits, use_trajectory=use_trajectory, seed=seed, device=device)

    suffix = "" if use_trajectory else "_pose_only"
    ckpt = BACKEND_DIR / cfg["output"]["checkpoint"]
    ckpt = ckpt.with_name(f"{ckpt.stem}{suffix}{ckpt.suffix}")
    ckpt.parent.mkdir(parents=True, exist_ok=True)
    torch.save(result.pop("checkpoint"), ckpt)
    metrics = BACKEND_DIR / cfg["output"]["metrics"]
    metrics = metrics.with_name(f"{metrics.stem}{suffix}_seed{seed}{metrics.suffix}")
    metrics.parent.mkdir(parents=True, exist_ok=True)
    metrics.write_text(json.dumps(result, indent=2), encoding="utf-8")
    test = result.get("test", {})
    print(f"saved {ckpt.name}; test macro accuracy {test.get('macro_accuracy', float('nan')):.3f}")


if __name__ == "__main__":
    main()
