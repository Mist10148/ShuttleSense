"""Train the 1D CNN stroke classifier (T3.8, T3.9).

Usage: python scripts/train_stroke_classifier.py --config configs/stroke_cnn.yaml
"""

from __future__ import annotations

import argparse
from pathlib import Path

from shuttlesense.config import load_config

BACKEND_DIR = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=BACKEND_DIR / "configs" / "stroke_cnn.yaml")
    parser.add_argument("--pose-only", action="store_true", help="ablation: drop shuttle features")
    args = parser.parse_args()
    cfg = load_config(args.config)
    # TODO(T3.8): load features + splits, build shuttlesense.strokes.model.build_model,
    # train with class weighting and early stopping, seed everything from cfg["seed"].
    # TODO(T3.9): save best checkpoint to cfg["output"]["checkpoint"] and test metrics
    # (macro accuracy, per-class F1, confusion matrix) to cfg["output"]["metrics"].
    raise SystemExit(f"Not implemented yet. Config seed: {cfg.get('seed')}")


if __name__ == "__main__":
    main()
