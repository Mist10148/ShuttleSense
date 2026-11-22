"""Rally summary and file exports (F13, FR-13)."""

from __future__ import annotations

import contextlib
import csv
import json
from collections import Counter
from pathlib import Path

from shuttlesense.atomic import atomic_open, atomic_write_text
from shuttlesense.schema import PLAYER_IDS, ClipRecord, PlayerSummary, Rally, Summary, is_doubles

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
    "hitter",
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
    # Added for the courtside referee (T12.4), after the original columns so scripts that
    # read columns by position keep working.
    "game",
    "server_id",
    "receiver_id",
    "call",
    "margin_cm",
    "decision",
    # v1.7: 1 when the players had changed ends, so near / far in this row are the ends then.
    "ends_swapped",
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

    def player(hits: list) -> PlayerSummary:
        return PlayerSummary(
            hits=len(hits),
            stroke_counts=dict(Counter(h.stroke for h in hits if h.stroke)),
            peak_speed_kmh=_peak([h.speed_kmh for h in hits]),
        )

    for side in ("near", "far"):
        summary.per_player[side] = player([h for h in record.hits if h.player == side])
    if is_doubles(record):  # each partner too; hits with an unknown hitter count for the side
        for slot in PLAYER_IDS:
            summary.per_player[slot] = player([h for h in record.hits if h.hitter == slot])
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


def _server(record: ClipRecord, rally: Rally) -> str | None:
    """Who served: the doubles slot when known, else the side that hit the first shot."""
    if rally.server_id is not None:
        return rally.server_id
    first = next((h for h in record.hits if h.rally_index == rally.index), None)
    return first.player if first is not None else None


def _decisions(record: ClipRecord) -> dict[int, str]:
    """Per rally, the referee's decisions in words: a call confirmed or overridden, a winner
    set or cleared (with its reason)."""
    out: dict[int, list[str]] = {}
    for c in record.line_calls:
        if c.override is not None:
            verb = "confirmed" if c.override.call == c.call else "overridden"
            out.setdefault(c.rally_index, []).append(f"call {verb} {c.override.call}")
    if record.score is not None:
        for c in record.score.corrections:
            if c.kind != "winner":
                continue
            what = f"winner {c.winner_after}" if c.winner_after else "cleared"
            if c.reason:
                what += f" ({c.reason})"
            out.setdefault(c.rally_index, []).append(what)
    return {k: "; ".join(v) for k, v in out.items()}


def match_stats(record: ClipRecord) -> dict | None:
    """The match in numbers (summary.json): games, points won on serve, the longest rally and
    the referee's decisions. None without the referee layer."""
    score = record.score
    if score is None:
        return None
    fps = record.fps or 30.0
    served = {"near": 0, "far": 0}
    held = {"near": 0, "far": 0}
    for r in record.rallies:
        server = _server(record, r)
        if server is None or r.winner is None or r.score_after is None:
            continue
        side = server[:4] if server.startswith("near") else server[:3]
        served[side] += 1
        held[side] += r.winner == side
    longest = max(record.rallies, key=lambda r: (r.stroke_count, r.end_frame - r.start_frame),
                  default=None)  # fmt: skip
    kinds = Counter(c.kind for c in score.corrections)
    return {
        "best_of": score.best_of,
        "start_games": score.start_games.model_dump() if score.start_games else None,
        "games": [g.model_dump() for g in score.games],
        "games_won": score.games_won.model_dump(),
        "match_winner": score.match_winner,
        # v1.7: near / far are the ends as they stand at the end of the session.
        "ends_swapped": score.ends_swapped,
        "conceded": kinds.get("concede", 0) > 0,
        "points_won_on_serve": {side: {"won": held[side], "served": served[side]}
                                for side in ("near", "far")},  # fmt: skip
        "longest_rally": None if longest is None else {
            "index": longest.index,
            "strokes": longest.stroke_count,
            "duration_s": round((longest.end_frame - longest.start_frame) / fps, 3),
        },
        "decisions": {
            "corrections": kinds.get("winner", 0),
            "awards": kinds.get("award", 0),
            "changes_of_ends": kinds.get("ends", 0),
            "line_call_overrides": sum(1 for c in record.line_calls if c.override is not None),
            "reasons": dict(Counter(c.reason for c in score.corrections if c.reason)),
        },
    }  # fmt: skip


def _fmt(value: float | None, digits: int) -> str:
    return "" if value is None else f"{value:.{digits}f}"


def keep_chat(record: ClipRecord, out_dir: Path) -> None:
    """Carry the coach chat over from the record.json a re-render is about to replace.

    The chat only lives in record.json (unlike overrides and corrections, which have their
    own files), so without this a re-render would erase it and reset the question limit.
    """
    from shuttlesense.schema import load_record

    path = out_dir / "record.json"
    if not path.exists():
        return
    # An unreadable old record has no chat worth keeping.
    with contextlib.suppress(OSError, ValueError):
        previous = load_record(path.read_text(encoding="utf-8"))
        if record.chat is None:
            record.chat = previous.chat
        record.practice_goals = previous.practice_goals
        record.decision_log = previous.decision_log
        record.interval_state = previous.interval_state


def write_exports(record: ClipRecord, out_dir: Path) -> None:
    """Write record.json, summary.json, heatmap.json, hits.csv and rallies.csv to out_dir.

    heatmap.json (analytics/heatmap.py) is written only with a calibrated court; a stale
    one from an earlier run without a court is removed.
    """
    from shuttlesense.analytics.heatmap import build_heatmap
    from shuttlesense.courtside import coaching_recap

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
        "match": match_stats(record),
        "coaching_recap": coaching_recap(record),
        "decision_log": [e.model_dump(mode="json") for e in record.decision_log],
    }
    atomic_write_text(out_dir / "summary.json", json.dumps(summary, indent=2))
    heatmap = build_heatmap(record)
    if heatmap is not None:
        atomic_write_text(out_dir / "heatmap.json", json.dumps(heatmap, separators=(",", ":")))
    else:
        (out_dir / "heatmap.json").unlink(missing_ok=True)

    with atomic_open(out_dir / "rallies.csv", newline="", encoding=CSV_ENCODING) as f:
        writer = csv.writer(f)
        writer.writerow(RALLIES_CSV_COLUMNS)
        calls = {c.rally_index: c for c in record.line_calls}
        decisions = _decisions(record)
        for r, s in zip(record.rallies, stats, strict=True):
            call = calls.get(r.index)
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
                    r.game if r.game is not None else "",
                    r.server_id or "",
                    r.receiver_id or "",
                    "" if call is None else call.effective_call,
                    "" if call is None else f"{call.margin_cm:.1f}",
                    decisions.get(r.index, ""),
                    int(r.ends_swapped),
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
                    h.hitter or "",
                ]
            )
