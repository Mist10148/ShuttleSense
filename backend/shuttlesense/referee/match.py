"""Match play from rally winners (P3 referee, D21): games, server, service court, intervals.

BWF Laws of Badminton, rally scoring (singles):
- a game goes to 21 with a 2-point lead, capped at 30 (scoring.game_winner);
- a match is one game or the best of three;
- the rally winner serves next; the winner of a game serves first in the next one;
- the server serves from the right service court when their score is even, else the left;
- a 60 s interval when the leading side first reaches 11, a change of ends after each game
  and at 11 in the deciding game.

Everything is a pure function of the rally winners in order, so a correction or a
line-call override re-derives the whole match. Undecided rallies (no winner) change
nothing. One camera cannot tell who served, so `first_server` comes from the user; until
it is known the server is the last rally winner.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field

from shuttlesense.schema import PlayerSide, Score, ScorePair

INTERVAL_AT = 11
OTHER: dict[PlayerSide, PlayerSide] = {"near": "far", "far": "near"}


@dataclass
class Step:
    """The match after one rally: its game and the game score (None once the match is over)."""

    game: int
    score_after: ScorePair | None


@dataclass
class MatchPlay:
    best_of: int = 1
    first_server: PlayerSide | None = None
    start: ScorePair = field(default_factory=ScorePair)
    steps: list[Step] = field(default_factory=list)
    score: Score = field(default_factory=Score)


def _wins_game(near: int, far: int) -> PlayerSide | None:
    from shuttlesense.referee.scoring import game_winner

    return game_winner(near, far)


def play(
    winners: Sequence[PlayerSide | None],
    start: ScorePair | None = None,
    *,
    best_of: int = 1,
    first_server: PlayerSide | None = None,
) -> MatchPlay:
    """Run the match over the rally winners and return each step and the final state."""
    if best_of not in (1, 3):
        raise ValueError("best_of must be 1 or 3")
    start = start or ScorePair()
    near, far = start.near, start.far
    game, games = 1, []
    won: dict[PlayerSide, int] = {"near": 0, "far": 0}
    server = first_server
    match_winner: PlayerSide | None = None
    interval = change_ends = False
    reached_interval = max(near, far) >= INTERVAL_AT  # joined after the interval
    steps: list[Step] = []
    for w in winners:
        if match_winner is not None:
            steps.append(Step(game=game, score_after=None))
            continue
        interval = change_ends = False
        if w is None:
            steps.append(Step(game=game, score_after=ScorePair(near=near, far=far)))
            continue
        near, far = (near + 1, far) if w == "near" else (near, far + 1)
        server = w
        steps.append(Step(game=game, score_after=ScorePair(near=near, far=far)))
        if not reached_interval and max(near, far) == INTERVAL_AT:
            reached_interval = interval = True
            change_ends = best_of > 1 and game == best_of  # the deciding game
        if _wins_game(near, far) is None:
            continue
        games.append(ScorePair(near=near, far=far))
        won[w] += 1
        interval = False
        if won[w] > best_of // 2:
            match_winner = w
            change_ends = False
            continue
        change_ends = True
        game += 1
        near, far = 0, 0
        reached_interval = False
        # The game winner serves first in the next game: server is already w.

    score = Score(near=near, far=far, best_of=best_of, first_server=first_server, game=game)
    if match_winner is not None:
        # The match is over: the score shows the last game, games lists every game.
        last = games[-1]
        score.near, score.far = last.near, last.far
    score.games = games
    score.games_won = ScorePair(near=won["near"], far=won["far"])
    score.match_winner = match_winner
    score.interval, score.change_ends = interval, change_ends
    if match_winner is None:
        score.server = server
        if server is not None:
            mine = near if server == "near" else far
            score.service_court = "right" if mine % 2 == 0 else "left"
        for side in ("near", "far"):
            after = (near + 1, far) if side == "near" else (near, far + 1)
            if _wins_game(*after) == side:
                score.game_point.append(side)
                if won[side] + 1 > best_of // 2:
                    score.match_point.append(side)
    return MatchPlay(best_of=best_of, first_server=first_server, start=start, steps=steps,
                     score=score)  # fmt: skip
