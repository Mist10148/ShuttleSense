"""Match play: games, server, service court, intervals (referee/match.py, D21)."""

from __future__ import annotations

import pytest

from shuttlesense.referee.match import play
from shuttlesense.schema import ScorePair


def test_service_court_follows_the_servers_score() -> None:
    score = play([], first_server="near").score
    assert (score.server, score.service_court) == ("near", "right")
    score = play(["near"]).score
    assert (score.server, score.service_court) == ("near", "left")
    score = play(["near", "far", "far"]).score  # 1-2: far serves on an even score
    assert (score.server, score.service_court) == ("far", "right")


def test_server_unknown_until_a_rally_is_won() -> None:
    score = play([None]).score
    assert score.server is None and score.service_court is None


def test_undecided_rally_keeps_score_and_server() -> None:
    result = play(["far", None], first_server="near")
    assert [s.score_after for s in result.steps] == [ScorePair(near=0, far=1)] * 2
    assert result.score.server == "far"


def test_single_game_ends_the_match() -> None:
    result = play(["near"] * 22)
    assert result.score.match_winner == "near" and result.score.games == [ScorePair(near=21)]
    assert (
        result.steps[20].score_after == ScorePair(near=21) and result.steps[21].score_after is None
    )
    assert (result.score.near, result.score.far) == (21, 0)
    assert result.score.server is None and not result.score.game_point


def test_best_of_three_starts_game_two_with_the_game_winner_serving() -> None:
    result = play(["far"] * 21 + ["near"], best_of=3, first_server="near")
    score = result.score
    assert score.games == [ScorePair(far=21)] and score.game == 2
    assert score.games_won == ScorePair(far=1)
    assert (score.near, score.far) == (1, 0) and score.server == "near"
    assert result.steps[20].game == 1 and result.steps[21].game == 2
    assert play(["far"] * 21, best_of=3).score.change_ends  # ends change after game 1


def test_cap_at_30() -> None:
    score = play(["near"], ScorePair(near=29, far=29)).score
    assert score.match_winner == "near" and (score.near, score.far) == (30, 29)


def test_game_and_match_point() -> None:
    assert play([], ScorePair(near=29, far=29)).score.game_point == ["near", "far"]
    assert play([], ScorePair(near=20, far=20)).score.game_point == []
    score = play(["near"] * 21 + ["near"] * 20, best_of=3).score
    assert score.game_point == ["near"] and score.match_point == ["near"]
    score = play(["near"] * 20, best_of=3).score  # game 1: a game point, not a match point
    assert score.game_point == ["near"] and score.match_point == []


def test_interval_at_11_and_change_of_ends_in_the_deciding_game() -> None:
    score = play(["near"] * 11, best_of=3).score
    assert score.interval and not score.change_ends
    assert not play(["near"] * 12, best_of=3).score.interval  # only on the rally that hit 11
    deciding = ["near"] * 21 + ["far"] * 21 + ["far"] * 11
    score = play(deciding, best_of=3).score
    assert score.game == 3 and score.interval and score.change_ends
    score = play(["near"] * 21 + ["far"] * 21 + ["near"] * 21, best_of=3).score
    assert score.match_winner == "near" and score.games_won == ScorePair(near=2, far=1)
    assert not score.change_ends


def test_start_score_past_11_has_no_interval() -> None:
    assert not play(["near"], ScorePair(near=11, far=3)).score.interval


def test_awards_count_before_the_rally_they_precede() -> None:
    from datetime import UTC, datetime

    from shuttlesense.referee import apply_rallies
    from shuttlesense.schema import Rally, ScoreCorrection

    rallies = [Rally(index=i, start_frame=i * 10, end_frame=i * 10 + 5, winner="near")
               for i in range(2)]  # fmt: skip
    award = ScoreCorrection(rally_index=1, winner_before=None, winner_after="far",
                            at=datetime.now(UTC), kind="award")  # fmt: skip
    score = apply_rallies(rallies, awards=[award])
    assert [r.score_after for r in rallies] == [ScorePair(near=1), ScorePair(near=2, far=1)]
    assert (score.near, score.far, score.server) == (2, 1, "near")


def test_best_of_must_be_1_or_3() -> None:
    with pytest.raises(ValueError):
        play([], best_of=2)
