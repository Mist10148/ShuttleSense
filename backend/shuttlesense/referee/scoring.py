"""BWF rally scoring rules (F16): 21 points, win by 2, capped at 30."""

from __future__ import annotations

from collections.abc import Sequence

from shuttlesense.schema import PlayerSide, Rally, ScorePair


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
