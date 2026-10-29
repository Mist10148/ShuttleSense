"""BWF rally scoring rules (F16): 21 points, win by 2, capped at 30."""

from __future__ import annotations

from shuttlesense.schema import PlayerSide


def game_winner(near: int, far: int) -> PlayerSide | None:
    """Return the game winner for a score, or None if the game is still on."""
    for side, mine, theirs in (("near", near, far), ("far", far, near)):
        if mine == 30 or (mine >= 21 and mine - theirs >= 2):
            return side
    return None
