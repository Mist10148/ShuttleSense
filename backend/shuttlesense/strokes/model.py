"""1D CNN stroke classifier (F6).

Input: (batch, features, time) windows built by scripts/extract_features.py.
Torch is imported lazily so the API and CI do not need it.
"""

from __future__ import annotations

from shuttlesense.schema import STROKE_CLASSES


def build_model(in_features: int, num_classes: int = len(STROKE_CLASSES), dropout: float = 0.3):
    """Return a small temporal CNN.

    TODO(T3.8): tune depth/width from configs/stroke_cnn.yaml and add the pose-only variant
    for the ablation (same network, fewer input features).
    """
    from torch import nn

    return nn.Sequential(
        nn.Conv1d(in_features, 64, kernel_size=5, padding=2),
        nn.BatchNorm1d(64),
        nn.ReLU(),
        nn.Conv1d(64, 128, kernel_size=5, padding=2),
        nn.BatchNorm1d(128),
        nn.ReLU(),
        nn.MaxPool1d(2),
        nn.Conv1d(128, 128, kernel_size=3, padding=1),
        nn.BatchNorm1d(128),
        nn.ReLU(),
        nn.AdaptiveAvgPool1d(1),
        nn.Flatten(),
        nn.Dropout(dropout),
        nn.Linear(128, num_classes),
    )
