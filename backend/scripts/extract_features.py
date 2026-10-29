"""Build pose + shuttle feature windows for the stroke classifier (T3.5).

Usage: python scripts/extract_features.py [--matches m01,m02] [--window 32] [--device cuda]
Input:  data/clips/<match_id>/index.csv and its clips (extract_clips.py)
Output: data/features/<match_id>.npz with X [N, T, F] (pose + shuttle), y [N] (index in
        STROKE_CLASSES) and meta [N] (clip names). Train with --pose-only to drop the shuttle
        columns; the file always holds both.
Splits are made separately by scripts/make_splits.py (T3.4).
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import numpy as np

DATA_DIR = Path(__file__).resolve().parent.parent / "data"


def hitter_side(record, hit_frame: int) -> str:
    """near/far: the player whose wrist is closest to the shuttle at the hit frame."""
    from shuttlesense.hits.detector import _wrist_distance, wrist_arrays

    frame = record.frames[min(hit_frame, len(record.frames) - 1)]
    s = frame.shuttle
    if s is None or not s.visible:
        return "near"
    point = np.array([s.x, s.y])
    d = {
        side: _wrist_distance(point, wrist_arrays(record, side)[frame.frame])
        for side in ("near", "far")
    }
    return min(d, key=d.get)


def perceive(clip: Path, device: str):
    """Run io + tracking + pose on one clip and return the record."""
    from shuttlesense.config import load_config
    from shuttlesense.pipeline import run_pipeline

    config = load_config()
    stages = config.setdefault("stages", {})
    for name in ("court", "hits", "strokes", "feedback", "analytics", "referee", "render"):
        stages.setdefault(name, {})["enabled"] = False
    out = clip.parent / ".perception" / clip.stem
    return run_pipeline(clip, out, clip_id=clip.stem, config=config, device=device)


def extract_match(match_dir: Path, window: int, device: str) -> int:
    from shuttlesense.schema import STROKE_CLASSES
    from shuttlesense.strokes.features import build_window
    from shuttlesense.strokes.labels import map_label

    X, y, meta = [], [], []
    with (match_dir / "index.csv").open(newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for row in rows:
        label = map_label(row["shuttleset_type"])
        if label is None:
            continue
        record = perceive(match_dir / row["clip"], device)
        hit = int(row["hit_frame_in_clip"])
        X.append(build_window(record, hit, hitter_side(record, hit), window, use_trajectory=True))
        y.append(STROKE_CLASSES.index(label))
        meta.append(row["clip"])
    out = DATA_DIR / "features" / f"{match_dir.name}.npz"
    out.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(out, X=np.stack(X) if X else np.zeros((0, window, 39)), y=np.array(y),
                        meta=np.array(meta))  # fmt: skip
    return len(y)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--window", type=int, default=32, help="frames per window")
    parser.add_argument("--matches", help="comma-separated match ids (default: all)")
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    args = parser.parse_args()

    from shuttlesense.config import detect_device

    device = detect_device(args.device)
    clips = DATA_DIR / "clips"
    match_dirs = sorted(p.parent for p in clips.glob("*/index.csv"))
    if args.matches:
        wanted = set(args.matches.split(","))
        match_dirs = [d for d in match_dirs if d.name in wanted]
    if not match_dirs:
        raise SystemExit(f"no clips under {clips}; run extract_clips.py first")
    for match_dir in match_dirs:
        print(f"{match_dir.name}: {extract_match(match_dir, args.window, device)} windows")


if __name__ == "__main__":
    main()
