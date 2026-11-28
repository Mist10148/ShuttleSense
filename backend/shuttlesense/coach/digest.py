"""Text digest of a clip record: everything the coach chat may send to the Claude API.

docs/PRIVACY.md lists what goes in. Pixels, keypoints, shuttle tracks and court corners
never do. The text is deterministic for a given record, so the API can cache it across the
questions of one session. When it would pass `max_chars`, per-hit lines are replaced by
per-rally summaries and the digest says it was shortened.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from shuttlesense.schema import ClipRecord, Hit, Moment, is_doubles


@dataclass
class Digest:
    text: str
    moments: list[Moment] = field(default_factory=list)  # every time the model may cite
    shortened: bool = False


def _t(seconds: float) -> str:
    return f"t={seconds:.1f}s"


def _hit_line(h: Hit) -> str:
    parts = [f"{_t(h.time_s)} hit {h.id} by {h.hitter or h.player}"]
    if h.stroke:
        conf = f" ({h.confidence:.0%})" if h.confidence is not None else ""
        parts.append(f"{h.stroke}{conf}")
    if h.speed_kmh is not None:
        parts.append(f"{h.speed_kmh:.0f} km/h est.")
    if h.rally_index is not None:
        parts.append(f"rally {h.rally_index}")
    form = [
        f"{f.rule} {'ok' if f.passed else 'FAIL'}"
        + (f" ({f.value:g})" if f.value is not None else "")
        for f in h.feedback
    ]
    if form:
        parts.append("form: " + ", ".join(form))
    return " | ".join(parts)


def _rally_lines(record: ClipRecord) -> list[str]:
    fps = record.fps or 30.0
    calls = {c.rally_index: c for c in record.line_calls}
    lines = []
    for r in record.rallies:
        s, e = r.start_frame / fps, r.end_frame / fps
        line = (
            f"rally {r.index}{_game(record, r.game)}: {_t(s)} to {_t(e)}, "
            f"{r.stroke_count} strokes, winner {r.winner or 'undecided'}"
        )
        if r.score_after is not None:
            line += f", score after {r.score_after.near}-{r.score_after.far} (near-far)"
        if r.server_id is not None:
            line += f", served by {r.server_id}"
            if r.receiver_id is not None:
                line += f" to {r.receiver_id}"
        if r.review:
            line += f"; referee note: {r.review}"
        call = calls.get(r.index)
        if call is not None:
            line += (
                f"; line call at {_t(call.time_s)}: {call.effective_call.upper()}, "
                f"{call.margin_cm:+.0f} cm from the line, confidence {call.confidence:.0%}"
            )
            if call.override is not None:
                line += f" (user set {call.override.call.upper()})"
            elif call.uncertain:
                line += " (UNCERTAIN, not confirmed)"
        lines.append(line)
    return lines


def _game(record: ClipRecord, game: int | None) -> str:
    """' (game N)' in a match of more than one game, so rallies of different games are told
    apart (each game's score starts again at 0-0)."""
    if record.score is None or record.score.best_of <= 1 or game is None:
        return ""
    return f" (game {game})"


def _score_lines(record: ClipRecord) -> list[str]:
    """The match result: per-game scores, games won and the winner, not only the last game."""
    score = record.score
    if score is None:
        return []
    lines = []
    if score.best_of > 1:
        games = ", ".join(f"game {i} {g.near}-{g.far}" for i, g in enumerate(score.games, 1))
        lines.append(
            f"Match: best of {score.best_of}; finished games (near-far): {games or 'none'}; "
            f"games won {score.games_won.near}-{score.games_won.far}."
        )
    if score.match_winner is not None:
        lines.append(f"Match won by {score.match_winner}.")
        last = score.games[-1] if score.games else score
        lines.append(f"Final game score {last.near}-{last.far} (near-far).")
    else:
        current = f"game {score.game} " if score.best_of > 1 else ""
        lines.append(f"Current {current}score {score.near}-{score.far} (near-far).")
    crossings = sum(r.change_ends for r in record.rallies) + sum(
        c.kind == "ends" for c in score.corrections
    )
    if crossings or score.ends_swapped:
        lines.append(
            f"The players changed ends {crossings} time(s). In every score, near and far are "
            "the ends of the court at that moment, so a side's points moved with it; the "
            + (
                "side that started near is now far."
                if score.ends_swapped
                else "sides are back at the ends they started at."
            )
        )
    reasons = [c.reason for c in score.corrections if getattr(c, "reason", None)]
    lines.append(
        f"{len(score.corrections)} manual referee decisions"
        + (f" ({', '.join(sorted(set(reasons)))})" if reasons else "")
        + "."
    )
    return lines


def _rally_summaries(record: ClipRecord) -> list[str]:
    """Short form: per rally, strokes by type and failed form rules, with hit times."""
    out = []
    groups: dict[int | None, list[Hit]] = {}
    for h in record.hits:
        groups.setdefault(h.rally_index, []).append(h)
    for index in sorted(groups, key=lambda i: -1 if i is None else i):
        hits = groups[index]
        strokes: dict[str, int] = {}
        for h in hits:
            strokes[h.stroke or "unclassified"] = strokes.get(h.stroke or "unclassified", 0) + 1
        fails = sorted(
            {f"{f.rule}@{_t(h.time_s)}" for h in hits for f in h.feedback if not f.passed}
        )
        label = "outside rallies" if index is None else f"rally {index}"
        line = f"{label}: {len(hits)} hits " + ", ".join(
            f"{k} {v}" for k, v in sorted(strokes.items())
        )
        if fails:
            line += "; failed form: " + ", ".join(fails[:12])
        out.append(line)
    return out


def _players_line(record: ClipRecord) -> str:
    if not is_doubles(record):
        return "Players are 'near' (closer to the camera) and 'far'."
    return (
        "Doubles: the sides are 'near' (closer to the camera) and 'far'. Each side has two "
        "partners: near_1 and near_2, far_1 and far_2. Lines for 'near' and 'far' are the "
        "pair's totals; a hit credited to 'near' or 'far' alone means the two partners were "
        "too close to tell which one hit."
    )


def build_digest(record: ClipRecord, max_chars: int = 24000) -> Digest:
    fps = record.fps or 30.0
    duration = record.num_frames / fps
    head = [
        f"Session: {record.mode}, {duration:.1f} s at {fps:g} fps, "
        f"court calibrated: {'yes' if record.court else 'no'}.",
        _players_line(record),
        "Speeds are 2D estimates. "
        "Line calls are automated estimates from one camera, not official calls.",
    ]
    if record.summary is not None:
        s = record.summary
        counts = ", ".join(f"{k} {v}" for k, v in sorted(s.stroke_counts.items())) or "none"
        head.append(f"Totals: {s.total_hits} hits; strokes: {counts}.")
        for side, p in sorted(s.per_player.items()):
            peak = f", peak {p.peak_speed_kmh:.0f} km/h est." if p.peak_speed_kmh else ""
            pc = ", ".join(f"{k} {v}" for k, v in sorted(p.stroke_counts.items())) or "none"
            head.append(f"{side}: {p.hits} hits ({pc}){peak}")
    head += _score_lines(record)
    notes = []
    if record.coaching is not None:
        top = set(record.coaching.top_fixes)
        for n in record.coaching.session_notes:
            when = ", ".join(_t(m.time_s) for m in n.moments)
            mark = "TOP FIX: " if n.id in top else ""
            notes.append(f"{mark}{n.text} [{when}]")

    moments = [Moment(frame=h.frame, time_s=h.time_s, hit_id=h.id) for h in record.hits]
    moments += [Moment(frame=c.frame, time_s=c.time_s) for c in record.line_calls]
    moments += [
        Moment(frame=f, time_s=round(f / fps, 3))
        for r in record.rallies
        for f in (r.start_frame, r.end_frame)
    ]
    if record.coaching is not None:
        moments += [m for n in record.coaching.session_notes for m in n.moments]

    def assemble(hit_lines: list[str], rally_lines: list[str]) -> str:
        # Notes come before the per-rally and per-hit detail, so trimming never drops them.
        sections = [
            "## Session", *head,
            "## Session notes", *(notes or ["no repeated patterns"]),
            "## Rallies", *(rally_lines or ["no rallies detected"]),
            "## Hits", *(hit_lines or ["no hits detected"]),
        ]  # fmt: skip
        return "\n".join(sections)

    rally_lines = _rally_lines(record)
    text = assemble([_hit_line(h) for h in record.hits], rally_lines)
    shortened = False
    if len(text) > max_chars:
        shortened = True
        hit_lines = ["(per-hit detail shortened to per-rally summaries)", *_rally_summaries(record)]
        text = assemble(hit_lines, rally_lines)
        # Still too long: leave out the oldest rallies' detail, newest first kept.
        while len(text) > max_chars and (len(hit_lines) > 1 or rally_lines):
            if len(hit_lines) > 1:
                hit_lines = [hit_lines[0], *hit_lines[2:]]
            else:
                rally_lines = rally_lines[1:]
            omitted = len(record.rallies) - len(rally_lines)
            note = [f"({omitted} earlier rallies left out)"] if omitted else []
            text = assemble(hit_lines, [*note, *rally_lines])
        text = text[:max_chars]
    return Digest(text=text, moments=moments, shortened=shortened)
