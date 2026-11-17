"""Display-only player boxes, including brief holds for missed observations."""

from __future__ import annotations

import math

from shuttlesense.schema import ClipRecord


def display_players(record: ClipRecord, index: int, hold_seconds: float = 0.6) -> dict:
    """Return boxes and hold state without changing the analysis record."""
    if not 0 <= index < len(record.frames) or not record.frames[index].player_hold_safe:
        return {}
    max_age = max(0, math.floor(max(0.0, hold_seconds) * (record.fps or 30.0)))
    output = {}
    for side in ("near", "far", "near_2", "far_2"):
        for offset in range(min(index, max_age) + 1):
            frame = record.frames[index - offset]
            if not frame.player_hold_safe:
                break
            player = getattr(frame.players, side)
            if player is not None:
                output[side] = {"bbox": list(player.bbox), "held": offset > 0}
                break
    return output
