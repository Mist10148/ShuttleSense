"""BWF rally scoring rules (F16): 21 points, win by 2, capped at 30; match play in match.py."""

from __future__ import annotations

import json
from collections.abc import Sequence
from pathlib import Path
from typing import TYPE_CHECKING, Any

from pydantic import TypeAdapter

from shuttlesense.atomic import atomic_write_text
from shuttlesense.schema import (
    ClipRecord,
    PlayerId,
    PlayerSide,
    Rally,
    Score,
    ScoreCorrection,
    ScorePair,
)

if TYPE_CHECKING:
    from shuttlesense.referee.linecalls import LineCallOverrideIn

# Score corrections live next to record.json, so a re-render (which rebuilds the record from
# the stage cache) can apply them again.
CORRECTIONS_FILE = "corrections.json"
_CORRECTIONS = TypeAdapter(list[ScoreCorrection])


def game_winner(near: int, far: int) -> PlayerSide | None:
    """Return the game winner for a score, or None if the game is still on."""
    for side, mine, theirs in (("near", near, far), ("far", far, near)):
        if mine == 30 or (mine >= 21 and mine - theirs >= 2):
            return side
    return None


def validate_start_score(score: ScorePair) -> None:
    """Raise ValueError unless the score can occur in a game that is still on."""
    if min(score.near, score.far) < 0:
        raise ValueError("start_score cannot be negative")
    if game_winner(score.near, score.far) is not None:
        raise ValueError("start_score is already a finished game")
    if max(score.near, score.far) > 29:  # 30 ends the game, so 30-30 or 31-31 never happen
        raise ValueError("start_score cannot go above 29 in a game that is still on")


def apply_rallies(
    rallies: Sequence[Rally],
    start: ScorePair | None = None,
    *,
    best_of: int = 1,
    first_server: PlayerSide | None = None,
    first_server_id: PlayerId | None = None,
    first_receiver_id: PlayerId | None = None,
    awards: Sequence[ScoreCorrection] = (),
) -> Score:
    """Set each rally's game and score_after from the winners and return the match score.

    Rallies without a winner (open or uncertain) keep the score. Once the match is won
    (the game, with best_of=1), later rallies get score_after = None and do not count.
    Awarded points count before the rally whose index they carry.
    """
    from shuttlesense.referee.match import play

    winners: list[PlayerSide | None] = []
    slots: list[Rally | None] = []  # the rally behind each winner, None for an award
    pending = sorted(awards, key=lambda a: a.rally_index)  # stable: given order within a slot
    for rally in rallies:
        while pending and pending[0].rally_index <= rally.index:
            winners.append(pending.pop(0).winner_after)
            slots.append(None)
        winners.append(rally.winner)
        slots.append(rally)
    winners += [a.winner_after for a in pending]
    slots += [None] * len(pending)
    result = play(winners, start, best_of=best_of, first_server=first_server,
                  first_server_id=first_server_id, first_receiver_id=first_receiver_id)  # fmt: skip
    for rally, step in zip(slots, result.steps, strict=True):
        if rally is not None:
            rally.game, rally.score_after = step.game, step.score_after
            rally.server_id, rally.receiver_id = step.server_id, step.receiver_id
    return result.score


def match_config(config: dict[str, Any]) -> dict[str, Any]:
    """best_of, first_server and the doubles first server and receiver slots from a job's
    config (`match`, set like start_score)."""
    match = config.get("match") or {}
    return {
        "best_of": int(match.get("best_of", 1)),
        "first_server": match.get("first_server"),
        "first_server_id": match.get("first_server_id"),
        "first_receiver_id": match.get("first_receiver_id"),
    }


def load_corrections(out_dir: Path) -> list[ScoreCorrection]:
    path = out_dir / CORRECTIONS_FILE
    if not path.exists():
        return []
    return _CORRECTIONS.validate_json(path.read_text(encoding="utf-8"))


def save_corrections(out_dir: Path, corrections: Sequence[ScoreCorrection]) -> None:
    data = _CORRECTIONS.dump_python(list(corrections), mode="json")
    atomic_write_text(out_dir / CORRECTIONS_FILE, json.dumps(data, indent=2))


def apply_corrections(
    record: ClipRecord, corrections: Sequence[ScoreCorrection], start: ScorePair | None = None
) -> None:
    """Set the corrected rally winners, keep the correction log and re-score every rally.

    Corrections for rallies that no longer exist (e.g. after a config change) are ignored.
    """
    if record.score is None:
        return
    by_index = {r.index: r for r in record.rallies}
    for c in corrections:
        if c.kind == "winner" and c.rally_index in by_index:
            by_index[c.rally_index].winner = c.winner_after
    awards = [c for c in corrections if c.kind == "award" and c.winner_after is not None]
    final = apply_rallies(record.rallies, start, best_of=record.score.best_of,
                          first_server=record.score.first_server,
                          first_server_id=record.score.first_server_id,
                          first_receiver_id=record.score.first_receiver_id,
                          awards=awards)  # fmt: skip
    final.corrections = list(corrections)
    record.score = final
    flag_service(record, start)


def flag_service(record: ClipRecord, start: ScorePair | None = None) -> None:
    """Doubles: mark rallies whose serve does not match the derived service order (T9.6).

    The order itself comes from the rally winners; this only asks the user to check a rally
    when pose disagrees: the serve was credited to the other partner, or the server's feet
    were not in the service court their side's score calls for. Nothing is changed.
    """
    from shuttlesense.schema import COURT_SIZE_M, side_of, slot_attr

    width = (record.court.court_size_m if record.court else COURT_SIZE_M)[0]
    score = start or ScorePair()
    game = 1
    for rally in record.rallies:
        rally.review = None
        if rally.game != game:
            game, score = rally.game, ScorePair()
        before = score
        if rally.score_after is not None:
            score = rally.score_after
        if rally.server_id is None:
            continue
        serve = next((h for h in record.hits if h.rally_index == rally.index), None)
        if serve is None:
            continue
        if serve.hitter is not None and serve.hitter != rally.server_id:
            rally.review = f"The serve looks like {serve.hitter}'s; {rally.server_id} should serve"
            continue
        frame = record.frames[serve.frame] if serve.frame < len(record.frames) else None
        pos = frame.court_positions if frame else None
        xy = getattr(pos, slot_attr(rally.server_id), None) if pos else None
        if xy is None:
            continue
        side = side_of(rally.server_id)
        mine = before.near if side == "near" else before.far
        expected = "right" if mine % 2 == 0 else "left"
        # Facing the net, a near player's right is +x and a far player's right is -x.
        on_right = (xy[0] > width / 2) == (side == "near")
        if ("right" if on_right else "left") != expected:
            rally.review = (
                f"{rally.server_id} should serve from the {expected} court at "
                f"{before.near}-{before.far}"
            )


def undo_last_correction(
    record: ClipRecord,
    start: ScorePair | None = None,
    overrides: Sequence[LineCallOverrideIn] = (),
) -> bool:
    """Take back the newest correction or award and re-score; False when there is none.

    A rally's winner goes back to what it was before that correction. Line-call overrides
    saved since then are applied again, as a re-render would (D10), so undo and re-render
    agree on the score.
    """
    if record.score is None or not record.score.corrections:
        return False
    *rest, last = record.score.corrections
    if last.kind == "winner":
        rally = next((r for r in record.rallies if r.index == last.rally_index), None)
        if rally is not None:
            rally.winner = last.winner_before
    if overrides:
        from shuttlesense.referee.linecalls import apply_overrides

        apply_overrides(record, list(overrides))
    apply_corrections(record, rest, start)
    return True


def apply_user_changes(record: ClipRecord, out_dir: Path, start: ScorePair | None = None) -> bool:
    """Re-apply the user's line-call overrides, then score corrections, from the job folder.

    Returns whether anything changed. Both files outlive re-renders (D10).
    """
    from shuttlesense.referee.linecalls import apply_overrides, load_overrides
    from shuttlesense.referee.rally import build_events

    overrides = load_overrides(out_dir)
    corrections = load_corrections(out_dir)
    if record.score is None or not (overrides or corrections):
        return False
    apply_overrides(record, overrides)
    apply_corrections(record, corrections, start)
    record.rally_events = build_events(record)
    return True
