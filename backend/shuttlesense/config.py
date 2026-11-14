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


def court_type(config: dict[str, Any]) -> str:
    """ "singles" or "doubles": the job's court, else stages.referee.line_call.court."""
    court = config.get("court")
    if court is None:
        referee = (config.get("stages") or {}).get("referee") or {}
        court = (referee.get("line_call") or {}).get("court", "singles")
    return "doubles" if court == "doubles" else "singles"


def with_court(config: dict[str, Any], court: str) -> dict[str, Any]:
    """A copy of `config` for a singles or doubles match: the top-level `court` key that pose,
    hits and match play read, and the line-call court of the referee stage."""
    stages = dict(config.get("stages") or {})
    referee = dict(stages.get("referee") or {})
    referee["line_call"] = {**(referee.get("line_call") or {}), "court": court}
    stages["referee"] = referee
    return {**config, "court": court, "stages": stages}


def with_stroke_model(config: dict[str, Any], name: str) -> dict[str, Any]:
    """A copy of `config` whose strokes stage uses the stroke model `name` (cnn, lstm, rf; D28).

    The choice sits inside stages.strokes, so the stage cache re-runs strokes, and what follows
    it, when a job is run again with another model."""
    stages = dict(config.get("stages") or {})
    stages["strokes"] = {**(stages.get("strokes") or {}), "algorithm": name}
    return {**config, "stages": stages}


def detect_device(preferred: str | None = None) -> str:
    """'cuda' if requested/available, else 'cpu'. Torch is optional."""
    if preferred in ("cpu", "cuda"):
        return preferred
    try:
        import torch
    except ImportError:
        return "cpu"
    return "cuda" if torch.cuda.is_available() else "cpu"
