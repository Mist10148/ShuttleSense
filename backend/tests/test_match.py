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


# Doubles service order (T9.6) ---------------------------------------------------------------


def test_doubles_service_order_follows_the_laws() -> None:
    """Hand-worked: near_1 serves to far_1 at 0-0; see referee/match.py for the rules."""
    m = play(["near", "far", "far", "near"], first_server_id="near_1", first_receiver_id="far_1")
    assert [(s.server_id, s.receiver_id) for s in m.steps] == [
        ("near_1", "far_1"),  # 0-0, right courts
        ("near_1", "far_2"),  # near won: same server, now from the left
        ("far_2", "near_1"),  # far won at 1-1: far_2 stands in far's left (odd) court
        ("far_2", "near_2"),  # far won again: far_2 moves to the right
    ]  # fmt: skip
    # Near won at 2-2: nobody moves, near_2 stands in near's right (even) court.
    assert (m.score.server_id, m.score.receiver_id) == ("near_2", "far_2")
    assert m.score.server == "near" and m.score.service_court == "right"
    assert (m.score.first_server_id, m.score.first_receiver_id) == ("near_1", "far_1")


def test_doubles_service_order_from_a_start_score_and_undecided_rallies() -> None:
    # At 3-0 near_1 serves from the left (odd), so far_1 receives in far's left court.
    m = play([None, "near"], ScorePair(near=3, far=0), first_server_id="near_1",
             first_receiver_id="far_1")  # fmt: skip
    assert [(s.server_id, s.receiver_id) for s in m.steps] == [
        ("near_1", "far_1"), ("near_1", "far_1"),
    ]  # fmt: skip
    # 4-0: near_1 serves again from the right, where far_2 stands.
    assert (m.score.server_id, m.score.receiver_id) == ("near_1", "far_2")


def test_doubles_slots_are_unknown_after_the_first_game() -> None:
    m = play(["far"] * 21 + ["near"], best_of=3, first_server_id="far_1",
             first_receiver_id="near_2")  # fmt: skip
    assert m.steps[20].server_id is not None and m.steps[21].server_id is None
    assert m.score.game == 2 and m.score.server_id is None


def test_doubles_service_order_in_later_games_from_the_named_slots() -> None:
    """D23: the user names game 2's first server and receiver; the order follows from there."""
    from shuttlesense.schema import GameService

    game2 = GameService(game=2, server_id="far_2", receiver_id="near_1")
    winners = ["far"] * 21 + ["far", "near", "near"]
    m = play(winners, best_of=3, first_server_id="far_1", first_receiver_id="near_2",
             game_service=[game2])  # fmt: skip
    assert m.score.game == 2
    assert [(s.server_id, s.receiver_id) for s in m.steps[21:]] == [
        ("far_2", "near_1"),  # 0-0 in game 2: far won game 1 and serves from the right
        ("far_2", "near_2"),  # far won: same server, from the left
        ("near_2", "far_2"),  # near won at 1-1: near_2 stands in near's left (odd) court
    ]  # fmt: skip
    assert m.score.game_service == [game2]
    # A named server on the side that lost the game cannot serve first: the slots are ignored.
    wrong = GameService(game=2, server_id="near_1", receiver_id="far_1")
    m = play(winners, best_of=3, first_server_id="far_1", first_receiver_id="near_2",
             game_service=[wrong])  # fmt: skip
    assert m.steps[21].server_id is None
    # Game 3 too.
    game3 = GameService(game=3, server_id="near_1", receiver_id="far_1")
    m = play(["far"] * 21 + ["near"] * 21 + ["near"], best_of=3, first_server_id="far_1",
             first_receiver_id="near_2", game_service=[game2, game3])  # fmt: skip
    assert m.steps[21].server_id == "far_2" and m.steps[42].server_id == "near_1"
    assert m.score.game == 3


def test_doubles_first_server_and_receiver_must_face_each_other() -> None:
    with pytest.raises(ValueError):
        play(["near"], first_server_id="near_1", first_receiver_id="near_2")
    with pytest.raises(ValueError):
        play(["near"], first_server="far", first_server_id="near_1", first_receiver_id="far_1")
    # Without the slots nothing changes for singles.
    assert play(["near"]).score.server_id is None


def test_pose_cross_check_flags_but_never_changes_the_score() -> None:
    from pathlib import Path

    from shuttlesense.referee.scoring import apply_corrections
    from shuttlesense.schema import load_record

    path = Path(__file__).parent / "fixtures" / "golden_record_doubles.json"
    record = load_record(path.read_text(encoding="utf-8"))
    serve = record.hits[0]
    width = record.court.court_size_m[0]
    # near_1 serves at 0-0: from near's right court, which is +x for a near player.
    record.frames[serve.frame].court_positions.near = (width * 0.75, 3.0)
    apply_corrections(record, [])
    assert record.rallies[0].server_id == "near_1" and record.rallies[0].review is None
    record.frames[serve.frame].court_positions.near = (width * 0.25, 3.0)
    apply_corrections(record, [])
    assert "right court" in record.rallies[0].review
    assert (record.score.near, record.score.far) == (1, 0)
    serve.hitter = "near_2"
    apply_corrections(record, [])
    assert "near_2" in record.rallies[0].review


def test_pose_cross_check_counts_awarded_points() -> None:
    """An awarded point moves the server's court: the check must use the score with it."""
    from datetime import UTC, datetime
    from pathlib import Path

    from shuttlesense.referee.scoring import apply_corrections
    from shuttlesense.schema import ScoreCorrection, load_record, side_of, slot_attr

    path = Path(__file__).parent / "fixtures" / "golden_record_doubles.json"
    record = load_record(path.read_text(encoding="utf-8"))
    award = ScoreCorrection(rally_index=0, winner_before=None, winner_after="far",
                            at=datetime.now(UTC), kind="award")  # fmt: skip
    apply_corrections(record, [award])
    rally = record.rallies[0]
    serve = next(h for h in record.hits if h.rally_index == rally.index)
    serve.hitter = rally.server_id
    side = side_of(rally.server_id)
    assert side == "far"  # far won the awarded point, so far serves at 0-1
    width = record.court.court_size_m[0]
    # Far serves at 0-1, an odd score: the left court, which is +x for a far player.
    setattr(record.frames[serve.frame].court_positions, slot_attr(rally.server_id),
            (width * 0.75, 10.0))  # fmt: skip
    apply_corrections(record, [award])
    assert record.rallies[0].review is None
    setattr(record.frames[serve.frame].court_positions, slot_attr(rally.server_id),
            (width * 0.25, 10.0))  # fmt: skip
    apply_corrections(record, [award])
    assert "left court at 0-1" in record.rallies[0].review


def test_an_undecided_rally_keeps_the_interval_showing() -> None:
    score = play(["near"] * 11 + [None], best_of=3).score
    assert score.interval  # no point was played since 11
    assert play(["far"] * 21 + [None], best_of=3).score.change_ends
    assert not play(["near"] * 11 + [None, "far"], best_of=3).score.interval


def test_a_one_game_match_changes_ends_at_11() -> None:
    score = play(["near"] * 11).score
    assert score.interval and score.change_ends
    assert not play(["near"] * 12).score.change_ends


def test_joining_in_the_deciding_game() -> None:
    """start_games 1-1: game 3, ends change at 11, and one more game wins the match."""
    games = ScorePair(near=1, far=1)
    result = play(["near"] * 11, best_of=3, start_games=games)
    assert result.score.game == 3 and result.score.change_ends and result.score.interval
    assert result.score.interval_s == 60
    assert result.score.start_games == games
    result = play(["far"] * 21, best_of=3, start_games=games)
    assert result.score.match_winner == "far"
    assert result.score.games_won == ScorePair(near=1, far=2)


def test_joining_in_game_two_counts_the_game_already_won() -> None:
    result = play(["near"] * 21, best_of=3, start_games=ScorePair(near=1))
    assert result.score.match_winner == "near" and result.score.games == [ScorePair(near=21)]


@pytest.mark.parametrize(
    ("games", "best_of"),
    [(ScorePair(near=-1), 3), (ScorePair(near=2), 3), (ScorePair(far=1), 1)],
)
def test_start_games_must_fit_a_match_still_on(games: ScorePair, best_of: int) -> None:
    with pytest.raises(ValueError, match="start_games"):
        play([], best_of=best_of, start_games=games)


def test_interval_between_games_is_two_minutes() -> None:
    score = play(["near"] * 21, best_of=3).score
    assert score.game == 2 and score.interval and score.change_ends
    assert score.interval_s == 120
    score = play(["near"] * 22, best_of=3).score  # the next rally ends it
    assert not score.interval and score.interval_s is None


def test_a_concession_ends_the_match_without_a_point() -> None:
    result = play(["near", "far", None, "near"], best_of=3, concessions={2: "far"})
    assert result.score.match_winner == "far"
    assert (result.score.near, result.score.far) == (1, 1)  # the game being played
    assert result.steps[3].score_after is None  # nothing counts after it
    assert result.score.games_won == ScorePair()
