"""Common types shared by all pipeline stages."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from shuttlesense.schema import ClipRecord

ProgressCallback = Callable[[float], None]


@dataclass
class StageContext:
    """Everything a stage needs besides the record itself."""

    video_path: Path
    out_dir: Path
    config: dict[str, Any] = field(default_factory=dict)
    device: str = "cpu"
    overlays: tuple[str, ...] = ()
    progress: ProgressCallback = lambda _fraction: None

    def stage_config(self, name: str) -> dict[str, Any]:
        return self.config.get("stages", {}).get(name, {})


class Stage(Protocol):
    def __call__(self, record: ClipRecord, ctx: StageContext) -> ClipRecord: ...


class StageSkipped(Exception):
    """Raised by a stage whose inputs are missing (e.g. no court calibration)."""
