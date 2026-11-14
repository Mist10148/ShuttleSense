"""Import the pre-extracted ShuttleSet features published with BST (T11.2, D29).

Usage: python scripts/import_bst_features.py --src data/bst_download/extracted/dataset_npy
                [--out data/features] [--splits configs/splits_bst.json] [--window 30]

Get the source by hand: download `dataset_npy.rar` (ShuttleSet, merged types, 30 frames) from
the Google Drive link in https://github.com/Va6lue/BST-Badminton-Stroke-type-Transformer and
extract it. It holds one folder per split and stroke type:

    <split>/<Top|Bottom>_<type>/<clip>_joints.npy    [T, 2, 17, 2]  top player, bottom player
    <split>/<Top|Bottom>_<type>/<clip>_shuttle.npy   [T, 2]         x / width, y / height

Joints are RTMPose COCO-17 keypoints, centred on the player's box centre and divided by the
box diagonal (`pose_norm: bbox_diag` in strokes/features.py). The shuttle is TrackNetV3 output
and (0, 0) when it was not found. The hit is at the clip centre.

For each split this writes <out>/bst_<split>.npz with X [N, window, 39], y [N] and meta [N],
the layout of scripts/extract_features.py, and a splits file naming the three. The hitter is
the Top or Bottom player named by the folder; types map to the six classes through
strokes/labels.py, and types that map to no class (drives, unknown) are left out (D12).
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

import numpy as np

from shuttlesense.schema import NUM_KEYPOINTS, STROKE_CLASSES
from shuttlesense.strokes.features import POSE_FEATURES, num_features, shuttle_features
from shuttlesense.strokes.labels import SHUTTLESET_ZH_TO_EN, map_label

BACKEND_DIR = Path(__file__).resolve().parent.parent
SPLITS = ("train", "val", "test")
SIDES = {"Top": 0, "Bottom": 1}


def folder_label(name: str) -> tuple[int, int] | None:
    """(player index, class index) for a folder like "Top_殺球"; None if it is left out."""
    side, _, stroke_type = name.partition("_")
    if side not in SIDES or stroke_type not in SHUTTLESET_ZH_TO_EN:
        return None
    label = map_label(stroke_type)
    if label is None:
        return None
    return SIDES[side], STROKE_CLASSES.index(label)


def fit_length(arr: np.ndarray, window: int) -> np.ndarray:
    """Keep the first `window` frames, or pad with zero frames at the end."""
    if len(arr) >= window:
        return arr[:window]
    pad = np.zeros((window - len(arr), *arr.shape[1:]), dtype=arr.dtype)
    return np.concatenate([arr, pad])


def clip_window(joints: np.ndarray, shuttle: np.ndarray, player: int, window: int) -> np.ndarray:
    """[window, 39] features for one clip, as strokes.features.build_window would give."""
    if joints.ndim != 4 or joints.shape[1:] != (2, NUM_KEYPOINTS, 2) or shuttle.ndim != 2:
        raise ValueError(f"unexpected shapes {joints.shape} / {shuttle.shape}")
    pose = fit_length(joints[:, player].astype(np.float32), window)
    xy = fit_length(shuttle[:, :2].astype(np.float32), window)
    feats = np.zeros((window, num_features(True)), dtype=np.float32)
    feats[:, :POSE_FEATURES] = pose.reshape(window, POSE_FEATURES)
    feats[:, POSE_FEATURES:] = shuttle_features(xy, (xy != 0).any(axis=1))
    return np.nan_to_num(feats, nan=0.0, posinf=0.0, neginf=0.0)


def import_split(split_dir: Path, window: int) -> tuple[np.ndarray, np.ndarray, np.ndarray, int]:
    """(X, y, meta, skipped) for one split folder."""
    xs, ys, meta, skipped = [], [], [], 0
    for folder in sorted(p for p in split_dir.iterdir() if p.is_dir()):
        target = folder_label(folder.name)
        if target is None:
            skipped += sum(1 for _ in folder.glob("*_joints.npy"))
            continue
        player, label = target
        for joints_path in sorted(folder.glob("*_joints.npy")):
            clip = joints_path.name[: -len("_joints.npy")]
            shuttle_path = folder / f"{clip}_shuttle.npy"
            try:
                joints = np.load(joints_path, allow_pickle=False)
                shuttle = np.load(shuttle_path, allow_pickle=False)
                xs.append(clip_window(joints, shuttle, player, window))
            except (OSError, ValueError):
                skipped += 1
                continue
            ys.append(label)
            meta.append(f"{folder.name}/{clip}")
    x = np.stack(xs) if xs else np.zeros((0, window, num_features(True)), np.float32)
    return x, np.asarray(ys, dtype=np.int64), np.asarray(meta, dtype=str), skipped


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", type=Path, required=True, help="the extracted dataset_npy folder")
    parser.add_argument("--out", type=Path, default=BACKEND_DIR / "data" / "features")
    parser.add_argument("--splits", type=Path, default=BACKEND_DIR / "configs" / "splits_bst.json")
    parser.add_argument("--window", type=int, default=30, help="frames per window")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    names: dict[str, list[str]] = {}
    for split in SPLITS:
        split_dir = args.src / split
        if not split_dir.is_dir():
            raise SystemExit(f"{split_dir} not found: --src must hold train/, val/ and test/")
        x, y, meta, skipped = import_split(split_dir, args.window)
        name = f"bst_{split}"
        np.savez_compressed(args.out / f"{name}.npz", X=x, y=y, meta=meta)
        names[split] = [name]
        counts = Counter(STROKE_CLASSES[i] for i in y)
        per_class = ", ".join(f"{c} {counts.get(c, 0)}" for c in STROKE_CLASSES)
        print(f"{split}: {len(y)} windows ({per_class}); {skipped} left out")
    args.splits.write_text(json.dumps(names, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.splits}")


if __name__ == "__main__":
    main()
