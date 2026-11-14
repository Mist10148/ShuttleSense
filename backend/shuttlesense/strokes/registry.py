"""The stroke models a job can choose from (D28): 1D CNN, LSTM and Random Forest.

All three read the same feature window (strokes/features.py) and give the same classes.
`stages.strokes.algorithm` picks one; each has its own weights key in the same config block,
so the stage cache sees both the choice and a replaced file (cache.py).
"""

from __future__ import annotations

import importlib.util
from typing import Any, get_args

from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import StrokeModel

ALGORITHMS: tuple[StrokeModel, ...] = get_args(StrokeModel)
DEFAULT_ALGORITHM: StrokeModel = "cnn"

LABELS: dict[str, str] = {"cnn": "1D CNN", "lstm": "LSTM", "rf": "Random Forest"}
# Config key under stages.strokes holding each model's weights path, and the default path.
WEIGHT_KEYS: dict[str, str] = {"cnn": "weights", "lstm": "weights_lstm", "rf": "weights_rf"}
DEFAULT_WEIGHTS: dict[str, str] = {
    "cnn": "weights/strokes/stroke_cnn.pt",
    "lstm": "weights/strokes/stroke_lstm.pt",
    "rf": "weights/strokes/stroke_rf.npz",
}
# Packages each model imports at inference. The forest is plain NumPy arrays.
REQUIRES: dict[str, tuple[str, ...]] = {"cnn": ("torch",), "lstm": ("torch",), "rf": ()}


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
    return (BACKEND_DIR / weights_path(strokes_cfg, name)).is_file()


def installed_models(config: dict[str, Any] | None) -> list[str]:
    """Installed stroke models, in menu order (GET /health "stroke_models")."""
    cfg = (config or {}).get("stages", {}).get("strokes", {})
    if not cfg.get("enabled", True):
        return []
    return [name for name in ALGORITHMS if installed(cfg, name)]
