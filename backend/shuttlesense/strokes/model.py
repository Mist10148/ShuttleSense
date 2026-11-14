"""Neural stroke classifiers (F6): a 1D CNN and an LSTM (D28).

The CNN takes (batch, features, time) windows from strokes/features.py; the LSTM takes
(batch, time, features). Torch is imported lazily so the API and CI do not need it.
The Random Forest is in strokes/rf.py.
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


def build_lstm(
    in_features: int,
    num_classes: int = len(STROKE_CLASSES),
    dropout: float = 0.3,
    hidden: int = 128,
    layers: int = 2,
    bidirectional: bool = True,
):
    """LSTM over the window; the mean and the maximum of its outputs over time go through
    dropout and a linear layer. Input: (batch, time, features)."""
    import torch
    from torch import nn

    class StrokeLSTM(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.inp = nn.Sequential(nn.Linear(in_features, hidden), nn.ReLU())
            self.lstm = nn.LSTM(
                hidden,
                hidden,
                num_layers=layers,
                batch_first=True,
                bidirectional=bidirectional,
                dropout=dropout if layers > 1 else 0.0,
            )
            self.drop = nn.Dropout(dropout)
            self.head = nn.Linear(hidden * (2 if bidirectional else 1) * 2, num_classes)

        def forward(self, x):
            out, _ = self.lstm(self.inp(x))
            pooled = torch.cat([out.mean(dim=1), out.amax(dim=1)], dim=1)
            return self.head(self.drop(pooled))

    return StrokeLSTM()


def build_from_config(
    in_features: int,
    model_cfg: dict,
    num_classes: int = len(STROKE_CLASSES),
    kind: str = "cnn",
):
    """The network for a checkpoint or a training config; kind is "cnn" or "lstm"."""
    if kind == "lstm":
        return build_lstm(
            in_features,
            num_classes,
            dropout=model_cfg.get("dropout", 0.3),
            hidden=model_cfg.get("hidden", 128),
            layers=model_cfg.get("layers", 2),
            bidirectional=model_cfg.get("bidirectional", True),
        )
    if kind != "cnn":
        raise ValueError(f"no network for stroke model {kind!r}")
    return build_model(
        in_features,
        num_classes,
        dropout=model_cfg.get("dropout", 0.3),
        channels=model_cfg.get("channels", (64, 128, 128)),
        kernel_sizes=model_cfg.get("kernel_sizes", (5, 5, 3)),
    )
