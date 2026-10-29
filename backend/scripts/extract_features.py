"""Build pose + shuttle feature windows for the stroke classifier (T3.4, T3.5).

Usage: python scripts/extract_features.py
Output: data/features/<match_id>.npz (X: [N, T, F], y: [N]) and data/splits.json
"""

from __future__ import annotations

import argparse
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window", type=int, default=32, help="frames per window")
    parser.add_argument("--seed", type=int, default=42, help="seed for the match-level split")
    args = parser.parse_args()
    # TODO(T3.5): run tracking + pose on data/clips, normalize keypoints to the hitter's bbox,
    # add shuttle (x, y, visible, dx, dy), save one .npz per match.
    # TODO(T3.4): write data/splits.json split by match (70/15/15) with args.seed.
    raise SystemExit(f"Not implemented yet. Window: {args.window} frames")


if __name__ == "__main__":
    main()
