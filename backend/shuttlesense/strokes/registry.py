"""The stroke models a job can choose from (D28): 1D CNN, LSTM and Random Forest.

All three read the same feature window (strokes/features.py) and give the same classes.
`stages.strokes.algorithm` picks one; each has its own weights key in the same config block,
so the stage cache sees both the choice and a replaced file (cache.py).

"ensemble" (D37) is a fourth choice that runs the three and averages their probabilities
(strokes/classify.py). It has no weights of its own: it is installed when all three are.
"""

from __future__ import annotations

import importlib.util
from typing import Any, get_args

from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import StrokeModel

ALGORITHMS: tuple[StrokeModel, ...] = get_args(StrokeModel)
DEFAULT_ALGORITHM: StrokeModel = "cnn"

ENSEMBLE: StrokeModel = "ensemble"
# The trained models, in the order the ensemble runs them. The first is its lead member.
MEMBERS: tuple[StrokeModel, ...] = ("cnn", "lstm", "rf")

LABELS: dict[str, str] = {
    "cnn": "1D CNN",
    "lstm": "LSTM",
    "rf": "Random Forest",
    "ensemble": "Ensemble",
}
# Config key under stages.strokes holding each model's weights path, and the default path.
# The ensemble's entry is its lead member's file: code that loads "the model's checkpoint"
# to learn the window length (live and Watch sessions) gets a real one, and the three
# members share that layout.
WEIGHT_KEYS: dict[str, str] = {
    "cnn": "weights",
    "lstm": "weights_lstm",
    "rf": "weights_rf",
    "ensemble": "weights",
}
DEFAULT_WEIGHTS: dict[str, str] = {
    "cnn": "weights/strokes/stroke_cnn.pt",
    "lstm": "weights/strokes/stroke_lstm.pt",
    "rf": "weights/strokes/stroke_rf.npz",
    "ensemble": "weights/strokes/stroke_cnn.pt",
}
# Packages each model imports at inference. The forest is plain NumPy arrays.
REQUIRES: dict[str, tuple[str, ...]] = {
    "cnn": ("torch",),
    "lstm": ("torch",),
    "rf": (),
    "ensemble": ("torch",),
}


def members(name: str) -> tuple[str, ...]:
    """The trained models a choice runs: the three for the ensemble, else itself."""
    return MEMBERS if name == ENSEMBLE else (name,)


def all_weights(strokes_cfg: dict[str, Any], name: str) -> list[str]:
    """Every weights file a choice needs."""
    return [weights_path(strokes_cfg, m) for m in members(name)]


def algorithm(strokes_cfg: dict[str, Any]) -> str:
    """The configured algorithm name (not validated: an unknown name skips the stage)."""
    return str(strokes_cfg.get("algorithm") or DEFAULT_ALGORITHM)


def weights_path(strokes_cfg: dict[str, Any], name: str) -> str:
    return str(strokes_cfg.get(WEIGHT_KEYS[name]) or DEFAULT_WEIGHTS[name])


def _has(module: str) -> bool:
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


def installed(strokes_cfg: dict[str, Any], name: str) -> bool:
    """True when the model's packages and weights file are present on this server."""
    if name not in ALGORITHMS:
        return False
    if not all(_has(m) for m in REQUIRES[name]):
        return False
    return all((BACKEND_DIR / path).is_file() for path in all_weights(strokes_cfg, name))


def installed_models(config: dict[str, Any] | None) -> list[str]:
    """Installed stroke models, in menu order (GET /health "stroke_models")."""
    cfg = (config or {}).get("stages", {}).get("strokes", {})
    if not cfg.get("enabled", True):
        return []
    return [name for name in ALGORITHMS if installed(cfg, name)]
