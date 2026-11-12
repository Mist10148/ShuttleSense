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

Doubles (Phase 9, T9.6), from the user's first server and first receiver slots:
- the server serves from the court that matches their side's score (right on even) to the
  player diagonally opposite, who stands in the same-named court;
- the serving side wins the rally: the same server serves again, from the other court
  (the partners swap courts);
- the receiving side wins: they serve next and nobody moves; whoever of them stands in the
  court that matches their new score serves.
Who serves first in a later game is the winning side's choice, so the slots are unknown
(None) from the second game on.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field

from shuttlesense.schema import PlayerId, PlayerSide, Score, ScorePair, side_of

INTERVAL_AT = 11
OTHER: dict[PlayerSide, PlayerSide] = {"near": "far", "far": "near"}


@dataclass
class Step:
    """The match after one rally: its game and the game score (None once the match is over)."""

    game: int
    score_after: ScorePair | None
    server_id: PlayerId | None = None  # doubles: who served and received this rally
    receiver_id: PlayerId | None = None


@dataclass
class MatchPlay:
    best_of: int = 1
    first_server: PlayerSide | None = None
    start: ScorePair = field(default_factory=ScorePair)
    steps: list[Step] = field(default_factory=list)
    score: Score = field(default_factory=Score)


def _partner(slot: PlayerId) -> PlayerId:
    return slot[:-1] + ("2" if slot.endswith("1") else "1")  # type: ignore[return-value]


def _court(score: int) -> str:
    return "right" if score % 2 == 0 else "left"


class DoublesCourts:
    """Which partner stands in each service court, per side (doubles service order)."""

    def __init__(self, server: PlayerId, receiver: PlayerId, near: int, far: int) -> None:
        serving = side_of(server)
        court = _court(near if serving == "near" else far)
        other = "left" if court == "right" else "right"
        self.at: dict[str, dict[str, PlayerId]] = {
            serving: {court: server, other: _partner(server)},
            side_of(receiver): {court: receiver, other: _partner(receiver)},
        }
        self.serving: PlayerSide = serving

    def pair(self, near: int, far: int) -> tuple[PlayerId, PlayerId]:
        """(server, receiver) of the next rally at this score."""
        court = _court(near if self.serving == "near" else far)
        receiving: PlayerSide = "far" if self.serving == "near" else "near"
        return self.at[self.serving][court], self.at[receiving][court]

    def won(self, side: PlayerSide) -> None:
        if side == self.serving:  # same server, other court: the partners swap
            courts = self.at[side]
            courts["right"], courts["left"] = courts["left"], courts["right"]
        else:
            self.serving = side  # nobody moves


def _wins_game(near: int, far: int) -> PlayerSide | None:
    from shuttlesense.referee.scoring import game_winner

    return game_winner(near, far)


def play(
    winners: Sequence[PlayerSide | None],
    start: ScorePair | None = None,
    *,
    best_of: int = 1,
    first_server: PlayerSide | None = None,
    first_server_id: PlayerId | None = None,
    first_receiver_id: PlayerId | None = None,
) -> MatchPlay:
    """Run the match over the rally winners and return each step and the final state.

    With `first_server_id` and `first_receiver_id` (doubles, on opposite sides) every step
    and the score also say who serves and receives.
    """
    if best_of not in (1, 3):
        raise ValueError("best_of must be 1 or 3")
    start = start or ScorePair()
    near, far = start.near, start.far
    courts = None
    if first_server_id and first_receiver_id:
        if side_of(first_server_id) == side_of(first_receiver_id):
            raise ValueError("the first server and receiver must be on opposite sides")
        first_server = first_server or side_of(first_server_id)
        if side_of(first_server_id) != first_server:
            raise ValueError("first_server_id must be on the first_server side")
        courts = DoublesCourts(first_server_id, first_receiver_id, near, far)
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
        ids = courts.pair(near, far) if courts else (None, None)
        if w is None:
            # No point played: an interval or change of ends still stands.
            steps.append(Step(game, ScorePair(near=near, far=far), *ids))
            continue
        interval = change_ends = False
        near, far = (near + 1, far) if w == "near" else (near, far + 1)
        server = w
        if courts:
            courts.won(w)
        steps.append(Step(game, ScorePair(near=near, far=far), *ids))
        if not reached_interval and max(near, far) == INTERVAL_AT:
            reached_interval = interval = True
            # The deciding game, or a one-game match (BWF Laws 8.1.3 and Appendix 3).
            change_ends = game == best_of
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
        courts = None  # the game winners choose their server: unknown from here
        # The game winner serves first in the next game: server is already w.

    score = Score(near=near, far=far, best_of=best_of, first_server=first_server, game=game,
                  first_server_id=first_server_id, first_receiver_id=first_receiver_id)  # fmt: skip
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
        if courts:
            score.server_id, score.receiver_id = courts.pair(near, far)
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
