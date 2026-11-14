"""Random Forest stroke classifier (D28): summary features and a NumPy-only forest.

A forest cannot read a [T, F] window directly, so each window is reduced to one row of
summary values (`summary_features`). scikit-learn trains the forest (training only, see
scripts/train_stroke_classifier.py); `Forest.from_sklearn` then copies the trees into plain
arrays, saved as an .npz file. Inference walks those arrays with NumPy, so a server needs
neither scikit-learn nor a pickled model, and loading the file cannot run code.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import numpy as np

from shuttlesense.strokes.features import POSE_FEATURES

# COCO-17 joints used for the hand-made values.
NOSE, L_SHO, R_SHO, L_ELB, R_ELB, L_WRI, R_WRI = 0, 5, 6, 7, 8, 9, 10
L_HIP, R_HIP, L_KNEE, R_KNEE, L_ANK, R_ANK = 11, 12, 13, 14, 15, 16
ARM_JOINTS = (L_ELB, R_ELB, L_WRI, R_WRI)
# (a, b, c): the angle at b between b->a and b->c.
ANGLES = (
    (L_SHO, L_ELB, L_WRI),
    (R_SHO, R_ELB, R_WRI),
    (L_ELB, L_SHO, L_HIP),
    (R_ELB, R_SHO, R_HIP),
    (L_HIP, L_KNEE, L_ANK),
    (R_HIP, R_KNEE, R_ANK),
)


def _angles(pose: np.ndarray) -> np.ndarray:
    """[N, T, len(ANGLES)] joint angles in radians from pose [N, T, 17, 2]."""
    out = []
    for a, b, c in ANGLES:
        u = pose[:, :, a] - pose[:, :, b]
        v = pose[:, :, c] - pose[:, :, b]
        norm = np.linalg.norm(u, axis=-1) * np.linalg.norm(v, axis=-1)
        cos = (u * v).sum(-1) / np.maximum(norm, 1e-6)
        out.append(np.arccos(np.clip(cos, -1.0, 1.0)))
    return np.stack(out, axis=-1)


def summary_features(x: np.ndarray) -> np.ndarray:
    """[N, D] summary rows from windows [N, T, F] (F = 34 pose-only, or 39 with the shuttle).

    Per value: mean, standard deviation, minimum, maximum, and the mean of the three frames
    around the hit (the window centre). Then: wrist and elbow speed (peak, mean, and where the
    peak falls in the window); elbow, shoulder and knee angles (at the hit, minimum, maximum);
    wrist height against the nose and the shoulders at the hit; and, with a shuttle, how often
    it is seen, its mean step and speed before and after the hit, and its height range.
    """
    x = np.asarray(x, dtype=np.float32)
    n, t, f = x.shape
    mid = t // 2
    near = slice(max(mid - 1, 0), min(mid + 2, t))
    parts = [x.mean(1), x.std(1), x.min(1), x.max(1), x[:, near].mean(1)]

    pose = x[:, :, :POSE_FEATURES].reshape(n, t, -1, 2)
    speed = np.linalg.norm(np.diff(pose[:, :, ARM_JOINTS], axis=1), axis=-1)  # [N, T-1, 4]
    if speed.shape[1]:
        parts += [speed.max(1), speed.mean(1), speed.argmax(1) / max(t - 1, 1)]
    else:
        parts += [np.zeros((n, 3 * len(ARM_JOINTS)), np.float32)]
    ang = _angles(pose)
    parts += [ang[:, near].mean(1), ang.min(1), ang.max(1)]
    hit_pose = pose[:, near].mean(1)  # [N, 17, 2]; y grows downward
    shoulders_y = hit_pose[:, [L_SHO, R_SHO], 1].mean(1)
    wrists_y = hit_pose[:, [L_WRI, R_WRI], 1]
    parts += [
        wrists_y - hit_pose[:, [NOSE], 1],
        wrists_y - shoulders_y[:, None],
        hit_pose[:, [L_WRI, R_WRI], 0] - hit_pose[:, [L_SHO, R_SHO], 0],
    ]

    if f > POSE_FEATURES:
        sh = x[:, :, POSE_FEATURES:]
        seen = sh[:, :, 2] > 0.5
        before, after = slice(0, mid), slice(mid, t)

        def mean_seen(values: np.ndarray, part: slice) -> np.ndarray:
            mask = seen[:, part]
            return (values[:, part] * mask).sum(1) / np.maximum(mask.sum(1), 1)

        def share_seen(part: slice) -> np.ndarray:
            mask = seen[:, part]
            return mask.sum(1) / max(mask.shape[1], 1)

        dx, dy = sh[:, :, 3], sh[:, :, 4]
        step = np.hypot(dx, dy)
        any_seen = seen.any(1)
        y_min = np.where(any_seen, np.where(seen, sh[:, :, 1], np.inf).min(1), 0.0)
        y_max = np.where(any_seen, np.where(seen, sh[:, :, 1], -np.inf).max(1), 0.0)
        shuttle_cols = [
            seen.mean(1),
            share_seen(before),
            share_seen(after),
            mean_seen(dx, before),
            mean_seen(dy, before),
            mean_seen(dx, after),
            mean_seen(dy, after),
            mean_seen(step, before),
            mean_seen(step, after),
            step.max(1),
            mean_seen(sh[:, :, 0], before),
            mean_seen(sh[:, :, 1], before),
            mean_seen(sh[:, :, 0], after),
            mean_seen(sh[:, :, 1], after),
            y_min,
            y_max,
        ]
        parts.append(np.stack(shuttle_cols, axis=1))
    return np.concatenate([np.asarray(p, dtype=np.float32) for p in parts], axis=1)


class Forest:
    """A trained forest as flat arrays; `predict_proba` needs only NumPy."""

    def __init__(
        self,
        left: np.ndarray,
        right: np.ndarray,
        feature: np.ndarray,
        threshold: np.ndarray,
        value: np.ndarray,
        roots: np.ndarray,
        meta: dict[str, Any],
    ) -> None:
        self.left, self.right, self.feature = left, right, feature
        self.threshold, self.value, self.roots = threshold, value, roots
        self.meta = meta

    @classmethod
    def from_sklearn(cls, model, meta: dict[str, Any]) -> Forest:
        """Copy a fitted RandomForestClassifier. Child indices become global node numbers."""
        left, right, feature, threshold, value, roots = [], [], [], [], [], []
        offset = 0
        num_classes = len(meta["classes"])
        labels = np.asarray(model.classes_, dtype=int)
        for est in model.estimators_:
            tree = est.tree_
            is_leaf = tree.children_left < 0
            roots.append(offset)
            left.append(np.where(is_leaf, -1, tree.children_left + offset))
            right.append(np.where(is_leaf, -1, tree.children_right + offset))
            feature.append(np.where(is_leaf, 0, tree.feature))
            threshold.append(tree.threshold)
            counts = tree.value[:, 0, :]
            probs = np.zeros((len(counts), num_classes), dtype=np.float32)
            # A class absent from the training data has no column: place by class label.
            probs[:, labels] = counts / np.maximum(counts.sum(1, keepdims=True), 1e-12)
            value.append(probs)
            offset += tree.node_count
        return cls(
            np.concatenate(left).astype(np.int32),
            np.concatenate(right).astype(np.int32),
            np.concatenate(feature).astype(np.int32),
            np.concatenate(threshold).astype(np.float32),
            np.concatenate(value).astype(np.float32),
            np.asarray(roots, dtype=np.int32),
            meta,
        )

    def predict_proba(self, rows: np.ndarray) -> np.ndarray:
        """[N, classes] mean leaf distribution over the trees for summary rows [N, D]."""
        rows = np.asarray(rows, dtype=np.float32)
        total = np.zeros((len(rows), self.value.shape[1]), dtype=np.float64)
        for root in self.roots:
            node = np.full(len(rows), root, dtype=np.int64)
            while True:
                inner = np.flatnonzero(self.left[node] >= 0)
                if not len(inner):
                    break
                at = node[inner]
                go_left = rows[inner, self.feature[at]] <= self.threshold[at]
                node[inner] = np.where(go_left, self.left[at], self.right[at])
            total += self.value[node]
        return (total / max(len(self.roots), 1)).astype(np.float32)

    def save(self, path: Path) -> None:
        """Write the arrays compressed; leaf distributions are stored as float16."""
        np.savez_compressed(
            path,
            left=self.left,
            right=self.right,
            feature=self.feature,
            threshold=self.threshold,
            value=self.value.astype(np.float16),
            roots=self.roots,
            meta=np.array(json.dumps(self.meta)),
        )

    @classmethod
    def load(cls, path: Path) -> Forest:
        with np.load(path, allow_pickle=False) as data:
            return cls(
                data["left"],
                data["right"],
                data["feature"],
                data["threshold"],
                data["value"].astype(np.float32),
                data["roots"],
                json.loads(str(data["meta"])),
            )
