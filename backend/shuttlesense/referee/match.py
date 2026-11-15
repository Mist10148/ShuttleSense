"""Match play from rally winners (P3 referee, D21): games, server, service court, intervals.

BWF Laws of Badminton, rally scoring (singles):
- a game goes to 21 with a 2-point lead, capped at 30 (scoring.game_winner);
- a match is one game or the best of three;
- the rally winner serves next; the winner of a game serves first in the next one;
- the server serves from the right service court when their score is even, else the left;
- a 60 s interval when the leading side first reaches 11 and a 120 s interval between
  games; a change of ends after each game and at 11 in the deciding game;
- a side that retires concedes the match (a `concede` correction, v1.5).

Change of ends (v1.7). `near` and `far` are always the ends of the court at that moment: a
rally's winner is the end that won it, and a referee's point goes to the end tapped. With
`auto_change_ends` the match follows the players when the Laws send them across: the points,
the games won, the finished games, the server and the doubles slots swap ends, so the same
people keep their score. A manual change (`swaps`, an `ends` correction) does the same at its
place in the match, for players who change early or late, or not at all (it then cancels the
automatic one). Without `auto_change_ends` only the `change_ends` notice is raised, as before.

A session can join a match under way: `start` is the score of the current game and
`start_games` the games each side had already won, which set the game number.

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
(None) from the second game on unless the user names that game's first server and receiver
(`game_service`, D23). Slots whose server is not on the game winner's side are ignored: a
correction can change who won the game.
"""

from __future__ import annotations

from collections.abc import Collection, Mapping, Sequence
from dataclasses import dataclass, field

from shuttlesense.schema import GameService, PlayerId, PlayerSide, Score, ScorePair, side_of

INTERVAL_AT = 11
INTERVAL_S = 60  # at 11 (BWF Laws 16.2.1)
GAME_INTERVAL_S = 120  # between games (Laws 16.2.2)
OTHER: dict[PlayerSide, PlayerSide] = {"near": "far", "far": "near"}


@dataclass
class Step:
    """The match after one rally: its game and the game score (None once the match is over)."""

    game: int
    score_after: ScorePair | None
    server_id: PlayerId | None = None  # doubles: who served and received this rally
    receiver_id: PlayerId | None = None
    score_before: ScorePair | None = None  # the game score when the rally started
    ends_swapped: bool = False  # the ends had been changed when this step was played
    change_ends: bool = False  # and were changed by rule right after it


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

    def mirror(self) -> None:
        """The pairs change ends mid-game: each person keeps their service court (it goes by
        their own side's score) and takes the slot with the same number at the other end."""

        def across(slot: PlayerId) -> PlayerId:
            end = "far" if slot.startswith("near") else "near"
            return end + slot[slot.index("_") :]  # type: ignore[return-value]

        self.at = {
            OTHER[side]: {court: across(slot) for court, slot in courts.items()}  # type: ignore[index]
            for side, courts in self.at.items()
        }
        self.serving = OTHER[self.serving]


def validate_start_games(start_games: ScorePair | None, best_of: int) -> None:
    """Raise ValueError unless the games already won fit a match that is still on."""
    if start_games is None:
        return
    if min(start_games.near, start_games.far) < 0:
        raise ValueError("start_games cannot be negative")
    if max(start_games.near, start_games.far) > best_of // 2:
        raise ValueError("start_games is already a finished match")


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
    game_service: Sequence[GameService] = (),
    start_games: ScorePair | None = None,
    concessions: Mapping[int, PlayerSide] | None = None,
    auto_change_ends: bool = False,
    swaps: Collection[int] = (),
) -> MatchPlay:
    """Run the match over the rally winners and return each step and the final state.

    With `first_server_id` and `first_receiver_id` (doubles, on opposite sides) every step
    and the score also say who serves and receives; `game_service` does the same for games
    after the first. `concessions` maps a step index to the side that wins the match there
    because the other retired; that step plays no point. `swaps` holds the step indexes
    where the players changed ends by hand; such a step plays no point either. With
    `auto_change_ends` they also change by rule (see the module docstring).
    """
    later = {g.game: g for g in game_service}
    if best_of not in (1, 3):
        raise ValueError("best_of must be 1 or 3")
    validate_start_games(start_games, best_of)
    concessions = concessions or {}
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
    games: list[ScorePair] = []
    won: dict[PlayerSide, int] = {"near": 0, "far": 0}
    if start_games is not None:
        won = {"near": start_games.near, "far": start_games.far}
    game = 1 + won["near"] + won["far"]
    conceded = False
    server = first_server
    match_winner: PlayerSide | None = None
    interval = change_ends = False
    reached_interval = max(near, far) >= INTERVAL_AT  # joined after the interval
    swapped = False  # the side that started at the near end is at the far end
    steps: list[Step] = []

    def cross() -> None:
        """The players change ends: what belongs to a side goes with it."""
        nonlocal near, far, server, swapped
        near, far = far, near
        won["near"], won["far"] = won["far"], won["near"]
        games[:] = [ScorePair(near=g.far, far=g.near) for g in games]
        server = OTHER[server] if server is not None else None
        if courts:
            courts.mirror()
        swapped = not swapped

    for i, w in enumerate(winners):
        if match_winner is not None:
            steps.append(Step(game=game, score_after=None, ends_swapped=swapped))
            continue
        if i in swaps:
            # Changed by hand: also answers a "change ends" notice that was showing.
            cross()
            change_ends = False
            steps.append(Step(game, ScorePair(near=near, far=far), ends_swapped=swapped))
            continue
        ids = courts.pair(near, far) if courts else (None, None)
        before = ScorePair(near=near, far=far)
        if i in concessions:
            match_winner, conceded = concessions[i], True
            interval = change_ends = False
            steps.append(Step(game, ScorePair(near=near, far=far), *ids, score_before=before,
                              ends_swapped=swapped))  # fmt: skip
            continue
        if w is None:
            # No point played: an interval or change of ends still stands.
            steps.append(Step(game, ScorePair(near=near, far=far), *ids, score_before=before,
                              ends_swapped=swapped))  # fmt: skip
            continue
        interval = change_ends = False
        near, far = (near + 1, far) if w == "near" else (near, far + 1)
        server = w
        if courts:
            courts.won(w)
        step = Step(game, ScorePair(near=near, far=far), *ids, score_before=before,
                    ends_swapped=swapped)  # fmt: skip
        steps.append(step)
        if not reached_interval and max(near, far) == INTERVAL_AT:
            reached_interval = interval = True
            # The deciding game, or a one-game match (BWF Laws 8.1.3 and Appendix 3).
            change_ends = game == best_of
            if change_ends and auto_change_ends:
                cross()
                step.change_ends = True
        if _wins_game(near, far) is None:
            continue
        games.append(ScorePair(near=near, far=far))
        won[w] += 1
        interval = False
        if won[w] > best_of // 2:
            match_winner = w
            change_ends = False
            continue
        change_ends = interval = True  # the 120 s interval between games
        game += 1
        near, far = 0, 0
        reached_interval = False
        courts = None
        if auto_change_ends:
            cross()
            step.change_ends = True
        # The game winners choose their server: unknown unless the user named them. The game
        # winner serves first in the next game: `server` is that side, at the end it is at now.
        named = later.get(game)
        if (named and server is not None and side_of(named.server_id) == server
                and side_of(named.receiver_id) != server):  # fmt: skip
            courts = DoublesCourts(named.server_id, named.receiver_id, 0, 0)

    score = Score(near=near, far=far, best_of=best_of, first_server=first_server, game=game,
                  first_server_id=first_server_id, first_receiver_id=first_receiver_id,
                  game_service=sorted(later.values(), key=lambda g: g.game))  # fmt: skip
    if match_winner is not None and not conceded:
        # The match is over: the score shows the last game, games lists every game. After
        # a concession it shows the game that was being played.
        last = games[-1]
        score.near, score.far = last.near, last.far
    score.start_games = (
        start_games if start_games and (start_games.near or start_games.far) else None
    )
    score.games = games
    score.games_won = ScorePair(near=won["near"], far=won["far"])
    score.match_winner = match_winner
    score.interval, score.change_ends = interval, change_ends
    score.auto_change_ends, score.ends_swapped = auto_change_ends, swapped
    if interval:
        score.interval_s = GAME_INTERVAL_S if near == far == 0 else INTERVAL_S
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
