"""Stage orchestration: ordering, enable/disable, progress reporting and exports."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from shuttlesense import (
    analytics,
    court,
    feedback,
    hits,
    io,
    pose,
    referee,
    render,
    strokes,
    tracking,
)
from shuttlesense.analytics import write_exports
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import Stage, StageContext, StageSkipped


@dataclass(frozen=True)
class StageSpec:
    name: str
    fn: Stage
    needs_court: bool = False
    referee: bool = False


# Execution order. Names match docs/ARCHITECTURE.md and GET /health "stages".
STAGES: tuple[StageSpec, ...] = (
    StageSpec("io", io.run),
    StageSpec("tracking", tracking.run),
    StageSpec("pose", pose.run),
    StageSpec("court", court.run, needs_court=True),
    StageSpec("hits", hits.run),
    StageSpec("strokes", strokes.run),
    StageSpec("feedback", feedback.run),
    StageSpec("analytics", analytics.run),
    StageSpec("referee", referee.run, needs_court=True, referee=True),
    StageSpec("render", render.run),
)
STAGE_NAMES: tuple[str, ...] = tuple(s.name for s in STAGES)

# (stage name, status, progress 0..1); status is pending/running/done/skipped/failed.
StageEvent = Callable[[str, str, float], None]


def plan_stages(
    *,
    has_court: bool,
    referee_enabled: bool,
    disabled: Sequence[str] = (),
) -> list[tuple[StageSpec, bool]]:
    """Return (stage, enabled) for every stage in order."""
    plan = []
    for spec in STAGES:
        enabled = spec.name not in disabled
        if spec.needs_court and not has_court:
            enabled = False
        if spec.referee and not referee_enabled:
            enabled = False
        plan.append((spec, enabled))
    return plan


def run_pipeline(
    video_path: Path,
    out_dir: Path,
    *,
    clip_id: str,
    config: dict[str, Any] | None = None,
    court_corners_px: Sequence[Sequence[float]] | None = None,
    overlays: Sequence[str] = (),
    referee_enabled: bool = False,
    device: str = "cpu",
    on_event: StageEvent = lambda _name, _status, _progress: None,
) -> ClipRecord:
    """Run all enabled stages on one video and write record.json, summary.json, hits.csv."""
    config = dict(config or {})
    if court_corners_px:
        config["court_corners_px"] = [list(c) for c in court_corners_px]
    disabled = [n for n, opts in config.get("stages", {}).items() if not opts.get("enabled", True)]

    record = ClipRecord(
        clip_id=clip_id, source_name=video_path.name, fps=0, width=0, height=0, num_frames=0
    )
    plan = plan_stages(
        has_court=bool(court_corners_px), referee_enabled=referee_enabled, disabled=disabled
    )
    for spec, enabled in plan:
        on_event(spec.name, "pending" if enabled else "skipped", 0.0)

    for spec, enabled in plan:
        if not enabled:
            continue
        ctx = StageContext(
            video_path=video_path,
            out_dir=out_dir,
            config=config,
            device=device,
            overlays=tuple(overlays),
            progress=lambda p, name=spec.name: on_event(name, "running", p),
        )
        on_event(spec.name, "running", 0.0)
        try:
            record = spec.fn(record, ctx)
        except StageSkipped:
            on_event(spec.name, "skipped", 0.0)
            continue
        except Exception:
            on_event(spec.name, "failed", 0.0)
            raise
        on_event(spec.name, "done", 1.0)

    write_exports(record, out_dir)
    return record
