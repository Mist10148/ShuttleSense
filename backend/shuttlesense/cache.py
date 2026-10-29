"""Per-stage cache: out_dir/cache/<stage>.json holds the fields a stage owns (T2.8).

A stage is skipped when its cache file exists and its key matches. Keys are chained: each
one hashes the stage's config block, the video size, the schema version, the job inputs
(court corners) and the previous stage's key, so changing an upstream stage invalidates
everything after it. io and render are never cached (io is cheap and provides the frame
reader; render depends on the overlay choice).
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from shuttlesense.schema import SCHEMA_VERSION, ClipRecord

# stage -> (top-level record fields, per-frame fields) it writes; see ARCHITECTURE.md.
OWNED: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "tracking": ((), ("shuttle",)),
    "pose": ((), ("players",)),
    "court": (("court",), ()),
    "hits": (("hits",), ()),
    "strokes": (("hits",), ()),
    "feedback": (("hits",), ()),
    "analytics": (("hits", "summary"), ("court_positions", "shuttle_speed_kmh")),
    "referee": (("hits", "rallies", "score"), ("rally_state",)),
}


def initial_key(video_path: Path, config: dict[str, Any]) -> str:
    size = video_path.stat().st_size if video_path.exists() else 0
    payload = {"size": size, "schema": SCHEMA_VERSION, "corners": config.get("court_corners_px")}
    return _sha1(payload)


def next_key(previous: str, stage: str, enabled: bool, stage_config: dict[str, Any]) -> str:
    return _sha1({"prev": previous, "stage": stage, "on": enabled, "cfg": stage_config})


def _sha1(payload: Any) -> str:
    text = json.dumps(payload, sort_keys=True, default=str)
    return hashlib.sha1(text.encode("utf-8")).hexdigest()


def cache_path(out_dir: Path, stage: str) -> Path:
    return out_dir / "cache" / f"{stage}.json"


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
    if stage not in OWNED:
        return None
    path = cache_path(out_dir, stage)
    if not path.exists():
        return None
    try:
        cached = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if cached.get("config_hash") != key:
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
