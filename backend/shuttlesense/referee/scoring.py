"""BWF rally scoring rules (F16): 21 points, win by 2, capped at 30."""

from __future__ import annotations

import json
from collections.abc import Sequence
from pathlib import Path

from pydantic import TypeAdapter

from shuttlesense.atomic import atomic_write_text
from shuttlesense.schema import ClipRecord, PlayerSide, Rally, ScoreCorrection, ScorePair

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


def apply_rallies(rallies: Sequence[Rally], start: ScorePair | None = None) -> ScorePair:
    """Set each rally's score_after from its winner and return the final score.

    Rallies without a winner (open or uncertain) keep the score. Once the game is won,
    later rallies get score_after = None and do not count.
    """
    score = ScorePair(near=start.near, far=start.far) if start else ScorePair()
    over = game_winner(score.near, score.far) is not None
    for rally in rallies:
        if over:
            rally.score_after = None
            continue
        if rally.winner == "near":
            score = ScorePair(near=score.near + 1, far=score.far)
        elif rally.winner == "far":
            score = ScorePair(near=score.near, far=score.far + 1)
        rally.score_after = ScorePair(near=score.near, far=score.far)
        over = game_winner(score.near, score.far) is not None
    return score


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
    record.score.corrections = list(corrections)
    final = apply_rallies(record.rallies, start)
    record.score.near, record.score.far = final.near, final.far


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
