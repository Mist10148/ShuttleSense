"""Stage orchestration: ordering, enable/disable, progress reporting and exports."""

from __future__ import annotations

import importlib.util
import json
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from shuttlesense import (
    analytics,
    cache,
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
from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import ClipRecord, ScorePair
from shuttlesense.stage import Stage, StageContext, StageSkipped


@dataclass(frozen=True)
class StageSpec:
    name: str
    fn: Stage
    needs_court: bool = False
    referee: bool = False
    # Python packages the stage imports lazily, and config keys holding weight paths.
    requires: tuple[str, ...] = ()
    weights: tuple[str, ...] = ()


# Execution order. Names match docs/ARCHITECTURE.md and GET /health "stages".
STAGES: tuple[StageSpec, ...] = (
    StageSpec("io", io.run),
    StageSpec("tracking", tracking.run, requires=("torch",), weights=("tracknet_weights",)),
    StageSpec("pose", pose.run, requires=("rtmlib",)),
    StageSpec("court", court.run, needs_court=True),
    StageSpec("hits", hits.run),
    StageSpec("strokes", strokes.run, requires=("torch",), weights=("weights",)),
    StageSpec("feedback", feedback.run),
    StageSpec("analytics", analytics.run),
    StageSpec("referee", referee.run, needs_court=True, referee=True),
    StageSpec("render", render.run),
)
STAGE_NAMES: tuple[str, ...] = tuple(s.name for s in STAGES)

# (stage name, status, progress 0..1); status is pending/running/done/skipped/failed.
StageEvent = Callable[[str, str, float], None]


def _installed(module: str) -> bool:
    try:
        return importlib.util.find_spec(module) is not None
    except (ImportError, ValueError):
        return False


def available_stages(config: dict[str, Any] | None = None) -> list[str]:
    """Stages whose lazy imports and weight files are present (GET /health "stages").

    A stage that is missing either still runs, but skips itself and leaves its fields empty.
    """
    stage_cfg = (config or {}).get("stages", {})
    names = []
    for spec in STAGES:
        cfg = stage_cfg.get(spec.name, {})
        if not cfg.get("enabled", True):
            continue
        if not all(_installed(m) for m in spec.requires):
            continue
        paths = [cfg.get(key) for key in spec.weights]
        if not all(p and (BACKEND_DIR / p).exists() for p in paths):
            continue
        names.append(spec.name)
    return names


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
    """Run all enabled stages on one video and write record.json, summary.json, hits.csv.

    Stage results are cached in out_dir/cache (see cache.py), so running again in the same
    out_dir with only overlays changed re-runs io and render only. Wall time per stage goes
    to out_dir/timings.json.
    """
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

    reader = None
    key = cache.initial_key(video_path, config)
    installed = set(available_stages(config))
    timings: dict[str, float] = {}
    for spec, enabled in plan:
        stage_cfg = config.get("stages", {}).get(spec.name, {})
        key = cache.next_key(key, spec.name, enabled, stage_cfg, spec.name in installed)
        if not enabled:
            continue
        if cache.is_skipped(out_dir, spec.name, key):
            on_event(spec.name, "skipped", 0.0)
            timings[spec.name] = 0.0
            continue
        cached = cache.load(out_dir, spec.name, key, record)
        if cached is not None:
            record = cached
            on_event(spec.name, "done", 1.0)
            timings[spec.name] = 0.0
            continue
        ctx = StageContext(
            video_path=video_path,
            out_dir=out_dir,
            config=config,
            device=device,
            overlays=tuple(overlays),
            progress=lambda p, name=spec.name: on_event(name, "running", p),
            reader=reader,
        )
        on_event(spec.name, "running", 0.0)
        started = time.perf_counter()
        try:
            record = spec.fn(record, ctx)
            reader = ctx.reader
        except StageSkipped:
            cache.save_skipped(out_dir, spec.name, key)
            on_event(spec.name, "skipped", 0.0)
            continue
        except Exception:
            on_event(spec.name, "failed", 0.0)
            raise
        finally:
            timings[spec.name] = round(time.perf_counter() - started, 3)
        cache.save(out_dir, spec.name, key, record)
        on_event(spec.name, "done", 1.0)

    corrections = referee.load_corrections(out_dir)
    if corrections and record.score is not None:  # made in the app since the last run
        start = ScorePair(**config.get("start_score", {}) or {})
        referee.apply_corrections(record, corrections, start)
        record.summary = analytics.build_summary(record)
    write_exports(record, out_dir)
    (out_dir / "timings.json").write_text(json.dumps(timings, indent=2), encoding="utf-8")
    return record
