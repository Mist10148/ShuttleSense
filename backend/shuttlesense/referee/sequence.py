"""Make the rally winners add up with where each server stood (D65).

BWF Laws 10.1 and 11.1: a side serves from its right service court when its own score is
even and from its left when it is odd, in singles and in doubles. So a clear serve with the
server's feet located says the parity of the serving side's score at that moment. A run of
those observations checks the whole sequence of winners: a rally nobody could call, or a
close call that went the wrong way, leaves every later serve of one side in the wrong court.

The decoder is a min-sum Viterbi over the parities of both scores (4 states). Each rally
offers its options with a cost: a winner the referee stands behind (a certain landing, a
clear next serve) is the only option; a close call can flip at `flip_cost`; an undecided
rally can stay unscored at no cost or be filled at `fill_cost`. Every serve-court
observation that disagrees costs `violation_cost`. A rally changes only when every other
option costs at least `min_margin` more than the chosen one, which with the defaults takes
two consistent observations: a wrong point is worse than an unscored one (D45).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

import numpy as np

from shuttlesense.schema import ClipRecord, PlayerSide, ScorePair

SEQUENCE_DEFAULTS: dict[str, Any] = {
    "enabled": True,
    "fill_cost": 1.0,  # scoring a rally nobody could call
    "flip_cost": 2.5,  # giving a close call to the side it did not lean to
    "violation_cost": 4.0,  # a serve from the wrong court for the decoded score
    "min_margin": 3.5,  # how much better the change must be than any alternative
    "center_margin_m": 0.3,  # feet this close to the centre line say no service court
    # A finished game resets the score (and may change ends), so the parities are only
    # followed while neither side can have reached this many points.
    "max_points": 20,
}

Winner = PlayerSide | None
State = tuple[int, int]  # (near, far) score parity
STATES: tuple[State, ...] = ((0, 0), (0, 1), (1, 0), (1, 1))


def sequence_config(cfg: dict[str, Any] | None) -> dict[str, Any]:
    """stages.referee.sequence merged over the defaults."""
    return {**SEQUENCE_DEFAULTS, **((cfg or {}).get("sequence") or {})}


@dataclass(frozen=True)
class Step:
    """One rally for the decoder."""

    options: dict[Winner, float]  # the winners it may have, with their cost
    served: tuple[PlayerSide, int] | None = None  # the next server's side and score parity


def serve_parity(record: ClipRecord, serve: Any, margin_m: float) -> int | None:
    """The serving side's score parity from where the server stands: 0 in the right service
    court (even score), 1 in the left; None when the feet are unknown or on the centre line.

    Facing the net, a near player's right is +x and a far player's right is -x.
    """
    from shuttlesense.schema import COURT_SIZE_M

    if not 0 <= serve.frame < len(record.frames):
        return None
    pos = record.frames[serve.frame].court_positions
    xy = getattr(pos, serve.player_attr, None) if pos is not None else None
    if xy is None or not np.isfinite(xy).all():
        return None
    width = (record.court.court_size_m if record.court else COURT_SIZE_M)[0]
    x = float(xy[0])
    if abs(x - width / 2) < margin_m:
        return None
    on_right = (x > width / 2) == (serve.player == "near")
    return 0 if on_right else 1


def _advance(state: State, winner: Winner) -> State:
    if winner == "near":
        return (1 - state[0], state[1])
    if winner == "far":
        return (state[0], 1 - state[1])
    return state


def _emit(state: State, winner: Winner, served: tuple[PlayerSide, int] | None, v: float) -> float:
    """The cost of a serve observation after this rally, given its winner and the score."""
    if served is None:
        return 0.0
    side, parity = served
    cost = 0.0 if state[0 if side == "near" else 1] == parity else v
    if winner is not None and winner != side:
        cost += v  # the side that won the rally serves the next one
    return cost


def decode(steps: list[Step], start: ScorePair, cfg: dict[str, Any] | None = None) -> list[Winner]:
    """Each step's winner: its zero-cost option unless the evidence clearly says otherwise."""
    sc = sequence_config(cfg)
    v, margin = float(sc["violation_cost"]), float(sc["min_margin"])
    n = len(steps)
    init: State = (start.near % 2, start.far % 2)
    fwd = [{s: (0.0 if s == init else math.inf) for s in STATES}]
    for step in steps:
        row = dict.fromkeys(STATES, math.inf)
        for s, base in fwd[-1].items():
            if base == math.inf:
                continue
            for w, cost in step.options.items():
                nxt = _advance(s, w)
                row[nxt] = min(row[nxt], base + cost + _emit(nxt, w, step.served, v))
        fwd.append(row)
    bwd = [dict.fromkeys(STATES, 0.0) for _ in range(n + 1)]
    for k in range(n - 1, -1, -1):
        step = steps[k]
        for s in STATES:
            bwd[k][s] = min(
                cost + _emit(_advance(s, w), w, step.served, v) + bwd[k + 1][_advance(s, w)]
                for w, cost in step.options.items()
            )
    out: list[Winner] = []
    for k, step in enumerate(steps):
        default = min(step.options, key=lambda w: step.options[w])
        totals = {
            w: min(
                fwd[k][s] + cost + _emit(_advance(s, w), w, step.served, v)
                + bwd[k + 1][_advance(s, w)]
                for s in STATES
            )
            for w, cost in step.options.items()
        }  # fmt: skip
        best = min(totals, key=lambda w: totals[w])
        others = [t for w, t in totals.items() if w != best]
        if best is not None and best != default and all(t >= totals[best] + margin for t in others):
            out.append(best)
        else:
            out.append(default)
    return out


def decodable(count: int, start: ScorePair, cfg: dict[str, Any] | None = None) -> int:
    """How many rallies from the start can be followed before a game could have ended."""
    limit = int(sequence_config(cfg)["max_points"])
    return max(0, min(count, limit - max(start.near, start.far)))
