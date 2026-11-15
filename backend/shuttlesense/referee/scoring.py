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
    GameService,
    PlayerId,
    PlayerSide,
    Rally,
    Score,
    ScoreCorrection,
    ScorePair,
)

if TYPE_CHECKING:
    from shuttlesense.referee.linecalls import LineCallOverrideIn
    from shuttlesense.referee.match import MatchPlay, Step

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
    game_service: Sequence[GameService] = (),
    start_games: ScorePair | None = None,
) -> Score:
    """Set each rally's game and score_after from the winners and return the match score.

    Rallies without a winner (open or uncertain) keep the score. Once the match is won
    (the game, with best_of=1), later rallies get score_after = None and do not count.
    Awarded points (and a concession, which ends the match) count before the rally whose
    index they carry.
    """
    pairs, result = _rally_steps(rallies, start, best_of=best_of, first_server=first_server,
                                 first_server_id=first_server_id,
                                 first_receiver_id=first_receiver_id, awards=awards,
                                 game_service=game_service,
                                 start_games=start_games)  # fmt: skip
    for rally, step in pairs:
        rally.game, rally.score_after = step.game, step.score_after
        rally.server_id, rally.receiver_id = step.server_id, step.receiver_id
    return result.score


def _rally_steps(
    rallies: Sequence[Rally],
    start: ScorePair | None,
    *,
    best_of: int,
    first_server: PlayerSide | None,
    first_server_id: PlayerId | None,
    first_receiver_id: PlayerId | None,
    awards: Sequence[ScoreCorrection],
    game_service: Sequence[GameService] = (),
    start_games: ScorePair | None = None,
) -> tuple[list[tuple[Rally, Step]], MatchPlay]:
    """Play the match over the rallies and awards: each rally's step, and the result."""
    from shuttlesense.referee.match import play

    winners: list[PlayerSide | None] = []
    slots: list[Rally | None] = []  # the rally behind each winner, None for an award
    concessions: dict[int, PlayerSide] = {}

    def add(decision: ScoreCorrection) -> None:
        if decision.kind == "concede" and decision.winner_after is not None:
            concessions[len(winners)] = decision.winner_after
            winners.append(None)
        else:
            winners.append(decision.winner_after)
        slots.append(None)

    pending = sorted(awards, key=lambda a: a.rally_index)  # stable: given order within a slot
    for rally in rallies:
        while pending and pending[0].rally_index <= rally.index:
            add(pending.pop(0))
        winners.append(rally.winner)
        slots.append(rally)
    for decision in pending:
        add(decision)
    result = play(winners, start, best_of=best_of, first_server=first_server,
                  first_server_id=first_server_id, first_receiver_id=first_receiver_id,
                  game_service=game_service, start_games=start_games,
                  concessions=concessions)  # fmt: skip
    pairs = [(r, step) for r, step in zip(slots, result.steps, strict=True) if r is not None]
    return pairs, result


def match_config(config: dict[str, Any]) -> dict[str, Any]:
    """best_of, first_server and the doubles first server and receiver slots from a job's
    config (`match`, set like start_score)."""
    match = config.get("match") or {}
    return {
        "best_of": int(match.get("best_of", 1)),
        "first_server": match.get("first_server"),
        "first_server_id": match.get("first_server_id"),
        "first_receiver_id": match.get("first_receiver_id"),
        "game_service": [GameService.model_validate(g) for g in match.get("game_service") or []],
        "start_games": ScorePair(**match["start_games"]) if match.get("start_games") else None,
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
    # A line-call override given after a winner correction on the same rally is the newer
    # decision, so that correction no longer applies (D32). apply_overrides ran first.
    overridden = {c.rally_index: c.override.at for c in record.line_calls if c.override}
    for c in corrections:
        if c.kind != "winner" or c.rally_index not in by_index:
            continue
        if c.rally_index in overridden and c.at < overridden[c.rally_index]:
            continue
        by_index[c.rally_index].winner = c.winner_after
    awards = [c for c in corrections if c.kind != "winner" and c.winner_after is not None]
    final = apply_rallies(record.rallies, start, best_of=record.score.best_of,
                          first_server=record.score.first_server,
                          first_server_id=record.score.first_server_id,
                          first_receiver_id=record.score.first_receiver_id,
                          awards=awards, game_service=record.score.game_service,
                          start_games=record.score.start_games)  # fmt: skip
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
    for rally in record.rallies:
        rally.review = None
    if record.score is None:
        return
    # The score before each rally comes from the same match steps that set server_id, so
    # awarded points (which are steps but not rallies) count.
    awards = [c for c in record.score.corrections
              if c.kind != "winner" and c.winner_after is not None]  # fmt: skip
    pairs, _ = _rally_steps(record.rallies, start, best_of=record.score.best_of,
                            first_server=record.score.first_server,
                            first_server_id=record.score.first_server_id,
                            first_receiver_id=record.score.first_receiver_id,
                            awards=awards, game_service=record.score.game_service,
                            start_games=record.score.start_games)  # fmt: skip
    before_of = {r.index: step.score_before for r, step in pairs}
    for rally in record.rallies:
        before = before_of.get(rally.index)
        if before is None or rally.server_id is None:
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


def changes_finished_match(before: Score | None, after: Score | None) -> bool:
    """True when the match was already won and a new decision left the result untouched.

    Such a decision falls after the deciding rally, so it would sit in the log (and on the
    undo stack) without doing anything; the API refuses it instead.
    """
    if before is None or after is None or before.match_winner is None:
        return False
    keep = {"corrections"}
    return before.model_dump(exclude=keep) == after.model_dump(exclude=keep)


def after_the_match(record: ClipRecord, rally_index: int) -> bool:
    """True when the match is won and this rally fell after the deciding one.

    Such a rally does not count (its score_after is None), so a line-call override on it
    cannot change the result; the API refuses it like any other decision there (D32). A
    call on a rally that did count can still be confirmed or overridden after the match.
    """
    if record.score is None or record.score.match_winner is None:
        return False
    rally = next((r for r in record.rallies if r.index == rally_index), None)
    return rally is not None and rally.score_after is None


def undo_last_decision(
    record: ClipRecord,
    start: ScorePair | None = None,
    overrides: Sequence[LineCallOverrideIn] = (),
) -> list[LineCallOverrideIn] | None:
    """Take back the newest referee decision and re-score; None when there is none.

    Score corrections, awards and line-call overrides form one log ordered by time (D32),
    so Undo always takes back what the referee did last. A rally's winner goes back to what
    it was before a correction; an undone override puts the automated call back. Returns the
    line-call overrides still in force, for the caller to keep or save.
    """
    from shuttlesense.referee.linecalls import apply_overrides, clear_override

    corrections = list(record.score.corrections) if record.score is not None else []
    remaining = sorted(overrides, key=lambda o: o.at)
    if not corrections and not remaining:
        return None
    if record.score is None:
        return None
    last_override = remaining[-1] if remaining else None
    last_correction = corrections[-1] if corrections else None
    if last_override is not None and (
        last_correction is None or last_override.at >= last_correction.at
    ):
        remaining = remaining[:-1]
        clear_override(record, last_override.rally_index)
    else:
        assert last_correction is not None
        corrections = corrections[:-1]
        if last_correction.kind == "winner":
            rally = next((r for r in record.rallies if r.index == last_correction.rally_index),
                         None)  # fmt: skip
            if rally is not None:
                rally.winner = last_correction.winner_before
    if remaining:
        apply_overrides(record, remaining)
    apply_corrections(record, corrections, start)
    return remaining


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
