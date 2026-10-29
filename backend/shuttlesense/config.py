"""Load pipeline settings from configs/pipeline.yaml."""

from __future__ import annotations

from pathlib import Path
from typing import Any

BACKEND_DIR = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = BACKEND_DIR / "configs" / "pipeline.yaml"


def load_config(path: Path | None = None) -> dict[str, Any]:
    """Return the YAML config as a dict, or {} if the file does not exist."""
    import yaml

    path = path or DEFAULT_CONFIG
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def detect_device(preferred: str | None = None) -> str:
    """'cuda' if requested/available, else 'cpu'. Torch is optional."""
    if preferred in ("cpu", "cuda"):
        return preferred
    try:
        import torch
    except ImportError:
        return "cpu"
    return "cuda" if torch.cuda.is_available() else "cpu"
