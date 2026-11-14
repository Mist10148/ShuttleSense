"""Per-stage cache: out_dir/cache/<stage>.json holds the fields a stage owns (T2.8).

A stage is skipped when its cache file exists and its key matches. Keys are chained: each
one hashes the stage's config block (without display-only keys, plus any other block the stage
reads, see key_config), whether its packages and weights are installed, the
size and modification time of every file the config block names (weights, a precomputed
tracking CSV), the video file, the schema version, the job inputs (court corners) and the
previous stage's key, so changing an upstream stage invalidates everything after it. A stage
that skipped itself (StageSkipped) is cached as skipped, so installing its weights later makes
it, and every stage after it, run again. io and render are never cached (io is cheap and
provides the frame reader; render depends on the overlay choice).
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from shuttlesense.schema import SCHEMA_VERSION, ClipRecord

# Bump when OWNED changes so caches written with fewer fields miss instead of loading them.
CACHE_FORMAT = 3

# stage -> (top-level record fields, per-frame fields) it writes; see ARCHITECTURE.md.
OWNED: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "tracking": ((), ("shuttle",)),
    "pose": ((), ("players",)),
    "court": (("court",), ()),
    "hits": (("hits",), ()),
    "strokes": (("hits", "stroke_model"), ()),
    "feedback": (("hits",), ()),
    "analytics": (("hits", "summary"), ("court_positions", "shuttle_speed_kmh")),
    "referee": (("hits", "rallies", "score", "line_calls", "rally_events"), ("rally_state",)),
}


# Keys that only change drawing (read by render) or progress. Leaving them out of the key keeps
# a re-render with a longer trail from re-running tracking and every stage after it.
DISPLAY_ONLY = frozenset({"weight", "trail_length", "marker_duration_s"})

# Config blocks a stage reads besides its own.
EXTRA_BLOCKS: dict[str, tuple[str, ...]] = {"pose": ("court",)}


def key_config(stage: str, stages_config: dict[str, Any]) -> dict[str, Any]:
    """The part of stages.<...> config that can change what `stage` writes."""

    def strip(block: dict[str, Any]) -> dict[str, Any]:
        return {k: v for k, v in block.items() if k not in DISPLAY_ONLY}

    own = strip(stages_config.get(stage, {}))
    extra = {name: strip(stages_config.get(name, {})) for name in EXTRA_BLOCKS.get(stage, ())}
    return {**own, "_blocks": extra} if extra else own


def initial_key(video_path: Path, config: dict[str, Any]) -> str:
    stat = video_path.stat() if video_path.exists() else None
    payload = {
        "name": video_path.name,
        "size": stat.st_size if stat else 0,
        "mtime": stat.st_mtime_ns if stat else 0,
        "schema": SCHEMA_VERSION,
        "format": CACHE_FORMAT,
        "corners": config.get("court_corners_px"),
    }
    from shuttlesense.config import court_type

    if court_type(config) == "doubles":  # four players from pose on; singles keys unchanged
        payload["court"] = "doubles"
    return _sha1(payload)


def file_stamps(stage_config: dict[str, Any], base_dir: Path) -> dict[str, list[int]]:
    """(size, mtime) of each existing file a config value points at, keyed by config key.

    Paths are relative to base_dir (absolute paths stay absolute), as the stages read them.
    Replacing weights or re-running TrackNetV3 into the same CSV then invalidates the cache.
    """
    stamps = {}
    for name, value in stage_config.items():
        if not isinstance(value, str) or not value:
            continue
        path = base_dir / value
        try:
            if path.is_file():
                stat = path.stat()
                stamps[name] = [stat.st_size, stat.st_mtime_ns]
        except OSError:
            continue
    return stamps


def next_key(
    previous: str,
    stage: str,
    enabled: bool,
    stage_config: dict[str, Any],
    available: bool = True,
    files: dict[str, list[int]] | None = None,
) -> str:
    payload: dict[str, Any] = {"prev": previous, "stage": stage, "on": enabled, "cfg": stage_config}
    if not available:  # keeps keys of installed stages unchanged
        payload["missing"] = True
    if files:  # likewise for stages that name no file
        payload["files"] = files
    return _sha1(payload)


def _sha1(payload: Any) -> str:
    text = json.dumps(payload, sort_keys=True, default=str)
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def cache_path(out_dir: Path, stage: str) -> Path:
    return out_dir / "cache" / f"{stage}.json"


def save_skipped(out_dir: Path, stage: str, key: str) -> None:
    if stage not in OWNED:
        return
    path = cache_path(out_dir, stage)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"config_hash": key, "skipped": True}), encoding="utf-8")


def is_skipped(out_dir: Path, stage: str, key: str) -> bool:
    """True if this stage skipped itself last time with the same key."""
    cached = _read(out_dir, stage)
    return bool(cached and cached.get("config_hash") == key and cached.get("skipped"))


def _read(out_dir: Path, stage: str) -> dict[str, Any] | None:
    path = cache_path(out_dir, stage)
    if stage not in OWNED or not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def save(out_dir: Path, stage: str, key: str, record: ClipRecord) -> None:
    if stage not in OWNED:
        return
    top, per_frame = OWNED[stage]
    data = record.model_dump(mode="json", include=set(top))
    if per_frame:
        data["frames"] = [f.model_dump(mode="json", include=set(per_frame)) for f in record.frames]
    path = cache_path(out_dir, stage)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"config_hash": key, "fields": data}), encoding="utf-8")


def load(out_dir: Path, stage: str, key: str, record: ClipRecord) -> ClipRecord | None:
    """The record with the cached fields applied, or None on a miss."""
    cached = _read(out_dir, stage)
    if cached is None or cached.get("config_hash") != key or "fields" not in cached:
        return None
    fields = cached["fields"]
    frames = fields.pop("frames", None)
    if frames is not None and len(frames) != len(record.frames):
        return None
    data = record.model_dump(mode="json")
    data.update(fields)
    if frames is not None:
        for target, values in zip(data["frames"], frames, strict=True):
            target.update(values)
    return ClipRecord.model_validate(data)
