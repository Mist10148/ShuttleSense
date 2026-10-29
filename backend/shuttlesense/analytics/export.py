"""Rally summary and file exports (F13, FR-13)."""

from __future__ import annotations

import csv
import json
from collections import Counter
from pathlib import Path

from shuttlesense.atomic import atomic_open, atomic_write_text
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
RALLIES_CSV_COLUMNS = (
    "index",
    "start_frame",
    "end_frame",
    "start_s",
    "end_s",
    "stroke_count",
    "peak_speed_kmh",
    "winner",
    "landing_in",
    "landing_confidence",
    "score_near",
    "score_far",
)
# UTF-8 with a byte-order mark so Excel on Windows detects the encoding.
CSV_ENCODING = "utf-8-sig"


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


def rally_stats(record: ClipRecord) -> list[dict]:
    """Per rally: stroke count, duration and peak hit speed (summary.json, rallies.csv)."""
    fps = record.fps or 30.0
    stats = []
    for r in record.rallies:
        hits = [h for h in record.hits if r.start_frame <= h.frame <= r.end_frame]
        stats.append(
            {
                "index": r.index,
                "stroke_count": len(hits),
                "start_s": round(r.start_frame / fps, 3),
                "end_s": round(r.end_frame / fps, 3),
                "duration_s": round((r.end_frame - r.start_frame) / fps, 3),
                "peak_speed_kmh": _peak([h.speed_kmh for h in hits]),
            }
        )
    return stats


def _fmt(value: float | None, digits: int) -> str:
    return "" if value is None else f"{value:.{digits}f}"


def write_exports(record: ClipRecord, out_dir: Path) -> None:
    """Write record.json, summary.json, hits.csv and rallies.csv to out_dir."""
    out_dir.mkdir(parents=True, exist_ok=True)
    atomic_write_text(out_dir / "record.json", record.model_dump_json())

    stats = rally_stats(record)
    summary = {
        "clip_id": record.clip_id,
        "fps": record.fps,
        "summary": record.summary.model_dump() if record.summary else None,
        "score": record.score.model_dump(mode="json") if record.score else None,
        "rallies": [r.model_dump() for r in record.rallies],
        "rally_stats": stats,
    }
    atomic_write_text(out_dir / "summary.json", json.dumps(summary, indent=2))

    with atomic_open(out_dir / "rallies.csv", newline="", encoding=CSV_ENCODING) as f:
        writer = csv.writer(f)
        writer.writerow(RALLIES_CSV_COLUMNS)
        for r, s in zip(record.rallies, stats, strict=True):
            writer.writerow(
                [
                    r.index,
                    r.start_frame,
                    r.end_frame,
                    f"{s['start_s']:.3f}",
                    f"{s['end_s']:.3f}",
                    s["stroke_count"],
                    _fmt(s["peak_speed_kmh"], 1),
                    r.winner or "",
                    "" if r.landing is None else int(r.landing.in_court),
                    "" if r.landing is None else f"{r.landing.confidence:.2f}",
                    "" if r.score_after is None else r.score_after.near,
                    "" if r.score_after is None else r.score_after.far,
                ]
            )

    with atomic_open(out_dir / "hits.csv", newline="", encoding=CSV_ENCODING) as f:
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
