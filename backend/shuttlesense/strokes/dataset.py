"""Training data for the stroke CNN: .npz windows from scripts/extract_features.py (T3.8)."""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

import numpy as np

from shuttlesense.strokes.features import POSE_FEATURES, flip_window


def load_npz(features_dir: Path, match_ids: Sequence[str]) -> tuple[np.ndarray, np.ndarray]:
    """Concatenate X [N, T, F] and y [N] for the given matches."""
    xs, ys = [], []
    for m in match_ids:
        with np.load(Path(features_dir) / f"{m}.npz") as data:
            xs.append(data["X"].astype(np.float32))
            ys.append(data["y"].astype(np.int64))
    if not xs:
        return np.zeros((0, 0, 0), np.float32), np.zeros(0, np.int64)
    return np.concatenate(xs), np.concatenate(ys)


def shift_window(x: np.ndarray, shift: int) -> np.ndarray:
    """Move a [T, F] window `shift` frames later (earlier when negative); zeros fill the gap."""
    if not shift:
        return x
    x = np.roll(x, shift, axis=0)
    if shift > 0:
        x[:shift] = 0
    else:
        x[shift:] = 0
    return x


def augment(
    x: np.ndarray,
    rng: np.random.Generator,
    use_trajectory: bool,
    noise: float = 0.01,
    max_shift: int = 2,
) -> np.ndarray:
    """Random time shift (+-max_shift frames), horizontal flip (p=0.5) and Gaussian noise."""
    x = shift_window(x, int(rng.integers(-max_shift, max_shift + 1)))
    if rng.random() < 0.5:
        x = flip_window(x, use_trajectory)
    return x + rng.normal(0, noise, x.shape).astype(np.float32)


class StrokeDataset:
    """torch-compatible dataset yielding (X [F, T] float32, y int64)."""

    def __init__(
        self,
        features_dir: Path,
        match_ids: Sequence[str],
        use_trajectory: bool = True,
        augment_data: bool = False,
        seed: int = 42,
        max_shift: int = 2,
        noise: float = 0.01,
    ) -> None:
        x, self.y = load_npz(features_dir, match_ids)
        self.x = x if use_trajectory or x.size == 0 else x[:, :, :POSE_FEATURES]
        self.use_trajectory = use_trajectory
        self.augment_data = augment_data
        self.max_shift, self.noise = max_shift, noise
        self.rng = np.random.default_rng(seed)

    @property
    def in_features(self) -> int:
        return int(self.x.shape[2]) if self.x.ndim == 3 and len(self.x) else 0

    def __len__(self) -> int:
        return len(self.y)

    def __getitem__(self, i: int):
        x = self.x[i]
        if self.augment_data:
            x = augment(x.copy(), self.rng, self.use_trajectory, self.noise, self.max_shift)
        return np.ascontiguousarray(x.T, dtype=np.float32), self.y[i]

    def class_weights(self, num_classes: int) -> np.ndarray:
        """Inverse-frequency weights, normalized to mean 1 (absent classes get 0)."""
        counts = np.bincount(self.y, minlength=num_classes).astype(float)
        weights = np.where(counts > 0, counts.sum() / np.maximum(counts, 1), 0.0)
        present = weights > 0
        weights[present] /= weights[present].mean()
        return weights.astype(np.float32)
