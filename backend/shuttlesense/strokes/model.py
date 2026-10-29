"""1D CNN stroke classifier (F6).

Input: (batch, features, time) windows from strokes/features.py.
Torch is imported lazily so the API and CI do not need it.
"""

from __future__ import annotations

from collections.abc import Sequence

from shuttlesense.schema import STROKE_CLASSES


def build_model(
    in_features: int,
    num_classes: int = len(STROKE_CLASSES),
    dropout: float = 0.3,
    channels: Sequence[int] = (64, 128, 128),
    kernel_sizes: Sequence[int] = (5, 5, 3),
):
    """Temporal CNN: Conv1d+BN+ReLU blocks (max-pool after the second), global average pool,
    dropout, linear. The pose-only ablation is the same network with fewer input features."""
    from torch import nn

    layers: list[nn.Module] = []
    prev = in_features
    for i, (ch, k) in enumerate(zip(channels, kernel_sizes, strict=True)):
        layers += [
            nn.Conv1d(prev, ch, kernel_size=k, padding=k // 2),
            nn.BatchNorm1d(ch),
            nn.ReLU(),
        ]
        if i == 1:
            layers.append(nn.MaxPool1d(2))
        prev = ch
    layers += [
        nn.AdaptiveAvgPool1d(1),
        nn.Flatten(),
        nn.Dropout(dropout),
        nn.Linear(prev, num_classes),
    ]
    return nn.Sequential(*layers)


def build_from_config(in_features: int, model_cfg: dict, num_classes: int = len(STROKE_CLASSES)):
    return build_model(
        in_features,
        num_classes,
        dropout=model_cfg.get("dropout", 0.3),
        channels=model_cfg.get("channels", (64, 128, 128)),
        kernel_sizes=model_cfg.get("kernel_sizes", (5, 5, 3)),
    )
