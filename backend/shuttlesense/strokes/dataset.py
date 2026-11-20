"""Training data for the stroke CNN: .npz windows from scripts/extract_features.py (T3.8)."""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

import numpy as np

from shuttlesense.strokes.features import POSE_FEATURES, flip_window, sample_rows
from shuttlesense.strokes.motion import expand, expanded_features


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
    scale_jitter: float = 0.0,
    keypoint_dropout: float = 0.0,
    shuttle_dropout: float = 0.0,
    time_warp: float = 0.0,
) -> np.ndarray:
    """Random time shift (+-max_shift frames), horizontal flip (p=0.5) and Gaussian noise.

    Three optional steps make the windows look more like footage the models were not
    trained on (all off at 0, which is the original augmentation):

    - scale_jitter: the pose is scaled by a factor in 1 +- scale_jitter, as a looser or
      tighter player box does;
    - keypoint_dropout: each joint is zeroed for the whole window with this probability,
      as a joint the pose model keeps missing;
    - shuttle_dropout: with this probability the shuttle is hidden for a run of 2 to 8
      frames, as a gap in the track;
    - time_warp: the window is resampled around the hit at a speed in 1 +- time_warp, as a
      faster or slower swing (or a clip at another frame rate) does. Missing frames stay
      missing (features.sample_rows never bridges a gap).
    """
    if time_warp > 0:
        x = warp_window(x, 1.0 + rng.uniform(-time_warp, time_warp))
    x = shift_window(x, int(rng.integers(-max_shift, max_shift + 1)))
    if rng.random() < 0.5:
        x = flip_window(x, use_trajectory)
    if scale_jitter > 0:
        x[:, :POSE_FEATURES] *= 1.0 + rng.uniform(-scale_jitter, scale_jitter)
    if keypoint_dropout > 0:
        lost = np.repeat(rng.random(POSE_FEATURES // 2) < keypoint_dropout, 2)
        x[:, :POSE_FEATURES][:, lost] = 0
    has_shuttle = use_trajectory and x.shape[1] > POSE_FEATURES
    if shuttle_dropout > 0 and has_shuttle and rng.random() < shuttle_dropout:
        length = int(rng.integers(2, 9))
        start = int(rng.integers(0, max(1, len(x) - length + 1)))
        x[start : start + length, POSE_FEATURES:] = 0
        # The frame after the gap has no previous position, so its step is 0 (features.py).
        if start + length < len(x):
            x[start + length, POSE_FEATURES + 3 : POSE_FEATURES + 5] = 0
    return x + rng.normal(0, noise, x.shape).astype(np.float32)


def warp_window(x: np.ndarray, speed: float) -> np.ndarray:
    """Resample a [T, F] window about its middle frame at `speed` (>1 is a faster swing)."""
    t = len(x)
    mid = t // 2
    positions = mid + (np.arange(t) - mid) * speed
    out = np.zeros_like(x)
    present = np.any(x[:, :POSE_FEATURES] != 0, axis=1)
    out[:, :POSE_FEATURES], _ = sample_rows(x[:, :POSE_FEATURES], present, positions)
    if x.shape[1] > POSE_FEATURES:
        seen = x[:, POSE_FEATURES + 2] > 0.5
        sh, ok = sample_rows(x[:, POSE_FEATURES : POSE_FEATURES + 2], seen, positions)
        out[ok, POSE_FEATURES : POSE_FEATURES + 2] = sh[ok]
        out[ok, POSE_FEATURES + 2] = 1.0
        # The step from the previous sample, at the new speed (features.shuttle_features).
        step = ok[1:] & ok[:-1]
        out[1:, POSE_FEATURES + 3 : POSE_FEATURES + 5][step] = (sh[1:] - sh[:-1])[step]
    return out


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
        scale_jitter: float = 0.0,
        keypoint_dropout: float = 0.0,
        shuttle_dropout: float = 0.0,
        time_warp: float = 0.0,
        feature_version: int = 1,
        arrays: tuple[np.ndarray, np.ndarray] | None = None,
    ) -> None:
        # `arrays` (X, y) replaces the files, for cross-validation folds (scripts/cv_strokes.py).
        x, self.y = arrays if arrays is not None else load_npz(features_dir, match_ids)
        self.x = x if use_trajectory or x.size == 0 else x[:, :, :POSE_FEATURES]
        self.use_trajectory = use_trajectory
        self.augment_data = augment_data
        self.max_shift, self.noise = max_shift, noise
        self.scale_jitter, self.keypoint_dropout = scale_jitter, keypoint_dropout
        self.shuttle_dropout, self.time_warp = shuttle_dropout, time_warp
        self.feature_version = feature_version
        self.rng = np.random.default_rng(seed)

    @property
    def in_features(self) -> int:
        """Columns the model sees: the stored window plus the motion channels (motion.py)."""
        if self.x.ndim != 3 or not len(self.x):
            return 0
        return expanded_features(int(self.x.shape[2]), self.feature_version)

    def __len__(self) -> int:
        return len(self.y)

    def __getitem__(self, i: int):
        x = self.x[i]
        if self.augment_data:
            x = augment(
                x.copy(),
                self.rng,
                self.use_trajectory,
                self.noise,
                self.max_shift,
                self.scale_jitter,
                self.keypoint_dropout,
                self.shuttle_dropout,
                self.time_warp,
            )
        x = expand(x, self.feature_version)
        return np.ascontiguousarray(x.T, dtype=np.float32), self.y[i]

    def class_weights(self, num_classes: int) -> np.ndarray:
        """Inverse-frequency weights, normalized to mean 1 (absent classes get 0)."""
        counts = np.bincount(self.y, minlength=num_classes).astype(float)
        weights = np.where(counts > 0, counts.sum() / np.maximum(counts, 1), 0.0)
        present = weights > 0
        weights[present] /= weights[present].mean()
        return weights.astype(np.float32)
