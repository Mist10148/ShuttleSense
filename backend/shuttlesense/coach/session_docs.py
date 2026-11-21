"""Retrievable text documents for the RAG coach: one session, and the player's history.

Like the digest (docs/PRIVACY.md) these hold numbers and labels only: no pixels, keypoints,
shuttle tracks, court corners or file names. Session documents cite times as [t=12.3s], the form the
chat validates. History documents summarize every finished job in storage, oldest first,
plus one trend document; per-job summaries are cached by record.json modification time.
"""

from __future__ import annotations

import logging
import threading
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING

from shuttlesense.coach.index import Chunk
from shuttlesense.schema import STROKE_CLASSES, ClipRecord, Hit, load_record

if TYPE_CHECKING:
    from shuttlesense.api.jobs import JobManager
    from shuttlesense.api.storage import Storage

log = logging.getLogger(__name__)

# Form rule (docs/FEEDBACK_RULES.md) or note rule -> drill chunk in knowledge/drills.md.
RULE_DRILLS: dict[str, str] = {
    "contact_above_head": "kb:drills#shadow-overheads-for-high-contact",
    "elbow_extension": "kb:drills#throw-and-reach-for-a-straight-arm",
    "contact_above_shoulder": "kb:drills#early-drop-contact",
    "short_follow_through": "kb:drills#soft-drop-feeding",
    "lunge_knee_bend": "kb:drills#lunge-ladder",
    "racket_arm_forward": "kb:drills#net-reach-drill",
    "wrist_below_shoulder": "kb:drills#lift-under-the-shuttle",
    "contact_below_waist": "kb:drills#low-serve-practice",
    "stable_feet": "kb:drills#serve-stance-routine",
    "shots_out": "kb:drills#target-zones-for-fewer-errors",
    "formation": "kb:drills#doubles-rotation-drill",
}


def _t(seconds: float) -> str:
    return f"[t={seconds:.1f}s]"


def _counts(counter: dict[str, int] | Counter[str]) -> str:
    return ", ".join(f"{k} {v}" for k, v in sorted(counter.items())) or "none"


def _hit_text(h: Hit) -> str:
    who = h.hitter or h.player
    text = f"{_t(h.time_s)} {who} {h.stroke or 'unclassified stroke'}"
    if h.speed_kmh is not None:
        text += f" {h.speed_kmh:.0f} km/h est."
    fails = [f.rule for f in h.feedback if not f.passed]
    if fails:
        text += " (form fail: " + ", ".join(fails) + ")"
    return text


def measured_stats(record: ClipRecord, question: str) -> Chunk:
    """Full-record counts and measured maxima, independent of the retrieval window."""
    groups: dict[str, list[Hit]] = defaultdict(list)
    groups["all hits"] = record.hits
    for hit in record.hits:
        groups[hit.player].append(hit)
        if hit.hitter:
            groups[hit.hitter].append(hit)
    lines = []
    for player, hits in groups.items():
        counts = Counter(h.stroke or "unclassified" for h in hits)
        lines.append(f"{player}: {len(hits)} hits; stroke counts: {_counts(counts)}.")
        named = [k for k in STROKE_CLASSES if k.replace("_", " ") in question.lower()]
        for stroke in [None, *named]:
            measured = [
                h for h in hits if h.speed_kmh is not None and (not stroke or h.stroke == stroke)
            ]
            label = f"{player}, {stroke or 'all strokes'}"
            if measured:
                peak = max(measured, key=lambda h: h.speed_kmh)
                lines.append(
                    f"{label}: fastest measured {peak.speed_kmh:g} km/h (est.), "
                    f"{peak.stroke or 'unclassified stroke'} {_t(peak.time_s)}."
                )
            else:
                lines.append(f"{label}: no recorded speed estimate.")
    return Chunk("session:measurements", "Measured session statistics", "\n".join(lines))


def session_documents(record: ClipRecord) -> list[Chunk]:
    """Overview, score, per-player stats, stroke mix, line calls, coaching notes, rallies."""
    fps = record.fps or 30.0
    docs: list[Chunk] = []
    duration = record.num_frames / fps
    overview = [
        f"Session {record.mode}, {duration:.1f} s, {len(record.rallies)} rallies, "
        f"{len(record.hits)} hits, {len(record.line_calls)} line calls."
    ]
    docs.append(Chunk("session:overview", "Session overview", " ".join(overview)))

    if record.score is not None:
        s = record.score
        lines = [f"Score near-far {s.near}-{s.far}, game {s.game}, best of {s.best_of}."]
        if s.games:
            lines.append("Finished games: " + ", ".join(f"{g.near}-{g.far}" for g in s.games) + ".")
        if s.match_winner:
            lines.append(f"Match won by {s.match_winner}.")
        won = Counter(r.winner for r in record.rallies if r.winner)
        if won:
            lines.append(f"Rallies won: {_counts(won)}.")
        docs.append(Chunk("session:score", "Score and match result", " ".join(lines)))

    if record.summary is not None:
        s = record.summary
        docs.append(
            Chunk(
                "session:strokes",
                "Stroke distribution",
                f"Total {s.total_hits} hits. Stroke mix: {_counts(s.stroke_counts)}."
                + (f" Peak speed {s.peak_speed_kmh:.0f} km/h est." if s.peak_speed_kmh else ""),
            )
        )
        for side, p in sorted(s.per_player.items()):
            checked: Counter[str] = Counter()
            failed: Counter[str] = Counter()
            for h in record.hits:
                if side in (h.hitter, h.player):  # a pair's line counts both partners
                    for f in h.feedback:
                        checked[f.rule] += 1
                        failed[f.rule] += not f.passed
            form = ", ".join(f"{r} failed {failed[r]} of {checked[r]}" for r in sorted(checked))
            text = f"Player {side}: {p.hits} hits; strokes {_counts(p.stroke_counts)}"
            if p.peak_speed_kmh:
                text += f"; peak speed {p.peak_speed_kmh:.0f} km/h (est.)"
            text += f". Form rules: {form or 'none checked'}."
            docs.append(Chunk(f"session:player-{side}", f"Player {side} stats", text))

    if record.line_calls:
        calls = []
        for c in record.line_calls:
            text = (
                f"rally {c.rally_index} {_t(c.time_s)} {c.effective_call.upper()} "
                f"{c.margin_cm:+.0f} cm, confidence {c.confidence:.0%}"
            )
            if c.override is not None:
                text += f" (user set {c.override.call.upper()})"
            elif c.uncertain:
                text += " (UNCERTAIN)"
            calls.append(text)
        docs.append(Chunk("session:line-calls", "Line calls", "Line calls: " + "; ".join(calls)))

    if record.coaching is not None and record.coaching.session_notes:
        top = record.coaching.top_fixes
        notes = []
        for n in record.coaching.session_notes:
            mark = f"TOP FIX {top.index(n.id) + 1}: " if n.id in top else ""
            when = " ".join(_t(m.time_s) for m in n.moments)
            notes.append(f"{mark}{n.text} (rule {n.rule}) {when}".strip())
        docs.append(Chunk("session:coaching", "Coaching notes and top fixes", "\n".join(notes)))

    hits_by_rally: dict[int | None, list[Hit]] = {}
    for h in record.hits:
        hits_by_rally.setdefault(h.rally_index, []).append(h)
    for r in record.rallies:
        hits = hits_by_rally.get(r.index, [])
        text = (
            f"Rally {r.index} (game {r.game}) {_t(r.start_frame / fps)} to {_t(r.end_frame / fps)}"
            f", {r.stroke_count} strokes, winner {r.winner or 'undecided'}"
        )
        if r.score_after is not None:
            text += f", score after {r.score_after.near}-{r.score_after.far}"
        text += ". Hits: " + ("; ".join(_hit_text(h) for h in hits) or "none") + "."
        docs.append(Chunk(f"session:rally-{r.index}", f"Rally {r.index}", text))
    loose = hits_by_rally.get(None, [])
    if loose:
        docs.append(
            Chunk(
                "session:other-hits",
                "Hits outside rallies",
                "; ".join(_hit_text(h) for h in loose),
            )
        )
    return docs


# History --------------------------------------------------------------------------


@dataclass
class SessionSummary:
    job_id: str
    date: datetime
    duration_s: float
    hits: int
    strokes: dict[str, int]
    peak_speed: dict[str, float]
    rallies_won: dict[str, int]
    rallies: int
    match_winner: str | None
    note_rules: list[str] = field(default_factory=list)  # rule:player of session notes
    top_fixes: list[str] = field(default_factory=list)  # their text
    rule_checks: dict[str, tuple[int, int]] = field(default_factory=dict)  # failed, checked


def summarize(job_id: str, date: datetime, record: ClipRecord) -> SessionSummary:
    fps = record.fps or 30.0
    strokes: Counter[str] = Counter(h.stroke for h in record.hits if h.stroke)
    peak: dict[str, float] = {}
    if record.summary is not None:
        peak = {
            side: p.peak_speed_kmh
            for side, p in record.summary.per_player.items()
            if p.peak_speed_kmh
        }
    checks: dict[str, list[int]] = {}
    for h in record.hits:
        for f in h.feedback:
            c = checks.setdefault(f.rule, [0, 0])
            c[0] += not f.passed
            c[1] += 1
    notes = record.coaching.session_notes if record.coaching else []
    top = record.coaching.top_fixes if record.coaching else []
    return SessionSummary(
        job_id=job_id,
        date=date,
        duration_s=record.num_frames / fps,
        hits=len(record.hits),
        strokes=dict(strokes),
        peak_speed=peak,
        rallies_won=dict(Counter(r.winner for r in record.rallies if r.winner)),
        rallies=len(record.rallies),
        match_winner=record.score.match_winner if record.score else None,
        note_rules=[n.id for n in notes],
        top_fixes=[n.text for n in notes if n.id in top],
        rule_checks={r: (c[0], c[1]) for r, c in checks.items()},
    )


class HistoryCache:
    """Per-job summaries keyed by record.json mtime, so history questions stay cheap."""

    def __init__(self) -> None:
        self._items: dict[str, tuple[float, SessionSummary]] = {}
        self._lock = threading.Lock()

    def summaries(
        self, storage: Storage, jobs: JobManager, limit: int = 200
    ) -> list[SessionSummary]:
        out = []
        for job in jobs.list(limit):
            if job.status != "done":
                continue
            path: Path = storage.output_path(job.id, "record")
            try:
                mtime = path.stat().st_mtime
            except OSError:
                continue
            with self._lock:
                cached = self._items.get(job.id)
            if cached is None or cached[0] != mtime:
                try:
                    record = load_record(path.read_text(encoding="utf-8"))
                except (OSError, ValueError) as exc:
                    log.warning("history: skipping %s: %s", job.id, exc)
                    continue
                cached = (mtime, summarize(job.id, job.created_at, record))
                with self._lock:
                    self._items[job.id] = cached
            out.append(cached[1])
        return sorted(out, key=lambda s: s.date)


def _rate(won: dict[str, int], side: str) -> str:
    total = sum(won.values())
    return f"{won.get(side, 0)}/{total}" if total else "n/a"


def history_documents(summaries: list[SessionSummary]) -> list[Chunk]:
    """One document per session (date-ordered) and one trend document across them."""
    docs = []
    for i, s in enumerate(summaries, 1):
        peaks = ", ".join(f"{k} {v:.0f} km/h" for k, v in sorted(s.peak_speed.items()))
        fails = ", ".join(f"{r} failed {f}/{c}" for r, (f, c) in sorted(s.rule_checks.items()) if c)
        text = (
            f"Session {i} of {len(summaries)} on {s.date:%Y-%m-%d}: "
            f"{s.duration_s:.0f} s, {s.rallies} rallies, {s.hits} hits. "
            f"Strokes: {_counts(s.strokes)}. Peak speeds (est.): {peaks or 'n/a'}. "
            f"Rallies won near {_rate(s.rallies_won, 'near')}, far {_rate(s.rallies_won, 'far')}."
        )
        if s.match_winner:
            text += f" Match won by {s.match_winner}."
        if fails:
            text += f" Form checks: {fails}."
        if s.top_fixes:
            text += " Top fixes: " + "; ".join(s.top_fixes) + "."
        # Numbered, not by job id: nothing that identifies a file or job leaves the backend.
        docs.append(Chunk(f"history:session-{i}", f"Session on {s.date:%Y-%m-%d}", text))
    if summaries:
        docs.append(Chunk("history:trends", "Trends across sessions", _trends(summaries)))
    return docs


def _trends(summaries: list[SessionSummary]) -> str:
    lines = [
        f"{len(summaries)} finished sessions from {summaries[0].date:%Y-%m-%d} "
        f"to {summaries[-1].date:%Y-%m-%d}."
    ]
    recurring = Counter(r for s in summaries for r in set(s.note_rules))
    rec = [f"{r} in {n} sessions" for r, n in recurring.most_common() if n >= 2]
    lines.append("Recurring feedback: " + ("; ".join(rec) if rec else "none repeated") + ".")
    rules = sorted({r for s in summaries for r in s.rule_checks})
    for rule in rules:
        rates = []
        for s in summaries:
            f, c = s.rule_checks.get(rule, (0, 0))
            rates.append(f"{f / c:.0%}" if c else "-")
        lines.append(f"{rule} fail rate by session: {' -> '.join(rates)}.")
    for side in ("near", "far"):
        rates = [_rate(s.rallies_won, side) for s in summaries]
        lines.append(f"Rallies won by {side} by session: {' -> '.join(rates)}.")
        peaks = [f"{s.peak_speed[side]:.0f}" if side in s.peak_speed else "-" for s in summaries]
        lines.append(f"Peak speed {side} km/h est. by session: {' -> '.join(peaks)}.")
    mixes = []
    for s in summaries:
        total = sum(s.strokes.values())
        top = ", ".join(f"{k} {v / total:.0%}" for k, v in Counter(s.strokes).most_common(3))
        mixes.append(f"{s.date:%Y-%m-%d}: {top or 'none'}")
    lines.append("Stroke mix (top 3) by session: " + "; ".join(mixes) + ".")
    return "\n".join(lines)
