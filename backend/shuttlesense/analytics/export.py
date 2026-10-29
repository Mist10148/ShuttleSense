"""Rally summary and file exports (F13, FR-13)."""

from __future__ import annotations

import csv
import json
from collections import Counter
from pathlib import Path

from shuttlesense.schema import ClipRecord, PlayerSummary, Summary

HITS_CSV_COLUMNS = (
    "id",
    "frame",
    "time_s",
    "player",
    "stroke",
    "confidence",
    "speed_kmh",
    "tip",
    "rally_index",
)


def _peak(values: list[float | None]) -> float | None:
    present = [v for v in values if v is not None]
    return max(present) if present else None


def build_summary(record: ClipRecord) -> Summary:
    """Compute stroke counts and peak speeds from record.hits."""
    summary = Summary(
        total_hits=len(record.hits),
        stroke_counts=dict(Counter(h.stroke for h in record.hits if h.stroke)),
        peak_speed_kmh=_peak([h.speed_kmh for h in record.hits]),
    )
    for side in ("near", "far"):
        hits = [h for h in record.hits if h.player == side]
        summary.per_player[side] = PlayerSummary(
            hits=len(hits),
            stroke_counts=dict(Counter(h.stroke for h in hits if h.stroke)),
            peak_speed_kmh=_peak([h.speed_kmh for h in hits]),
        )
    return summary


def write_exports(record: ClipRecord, out_dir: Path) -> None:
    """Write record.json, summary.json and hits.csv to out_dir."""
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "record.json").write_text(record.model_dump_json(), encoding="utf-8")

    summary = {
        "clip_id": record.clip_id,
        "fps": record.fps,
        "summary": record.summary.model_dump() if record.summary else None,
        "score": record.score.model_dump(mode="json") if record.score else None,
        "rallies": [r.model_dump() for r in record.rallies],
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")

    with (out_dir / "hits.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(HITS_CSV_COLUMNS)
        for h in record.hits:
            tip = next((fb.tip for fb in h.feedback if fb.tip), "")
            writer.writerow(
                [
                    h.id,
                    h.frame,
                    f"{h.time_s:.3f}",
                    h.player,
                    h.stroke or "",
                    "" if h.confidence is None else f"{h.confidence:.3f}",
                    "" if h.speed_kmh is None else f"{h.speed_kmh:.1f}",
                    tip,
                    "" if h.rally_index is None else h.rally_index,
                ]
            )
