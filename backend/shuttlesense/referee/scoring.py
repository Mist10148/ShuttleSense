"""BWF rally scoring rules (F16): 21 points, win by 2, capped at 30; match play in match.py."""

from __future__ import annotations

import json
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from pydantic import TypeAdapter

from shuttlesense.atomic import atomic_write_text
from shuttlesense.schema import ClipRecord, PlayerSide, Rally, Score, ScoreCorrection, ScorePair

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
) -> Score:
    """Set each rally's game and score_after from the winners and return the match score.

    Rallies without a winner (open or uncertain) keep the score. Once the match is won
    (the game, with best_of=1), later rallies get score_after = None and do not count.
    """
    from shuttlesense.referee.match import play

    result = play([r.winner for r in rallies], start, best_of=best_of, first_server=first_server)
    for rally, step in zip(rallies, result.steps, strict=True):
        rally.game, rally.score_after = step.game, step.score_after
    return result.score


def match_config(config: dict[str, Any]) -> dict[str, Any]:
    """best_of and first_server from a job's config (`match`, set like start_score)."""
    match = config.get("match") or {}
    return {"best_of": int(match.get("best_of", 1)), "first_server": match.get("first_server")}


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
        if c.rally_index in by_index:
            by_index[c.rally_index].winner = c.winner_after
    final = apply_rallies(record.rallies, start, best_of=record.score.best_of,
                          first_server=record.score.first_server)  # fmt: skip
    final.corrections = list(corrections)
    record.score = final


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
