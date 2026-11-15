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


# --- change of ends (v1.7) ----------------------------------------------------------------


def test_the_score_follows_the_players_between_games() -> None:
    """One side wins game 1 at the near end and game 2 at the far end: 2-0, not 1-1."""
    game_one = ["near"] * 21
    result = play(game_one, best_of=3, auto_change_ends=True)
    score = result.score
    assert score.ends_swapped and score.change_ends and score.auto_change_ends
    assert score.games_won == ScorePair(near=0, far=1)  # the game winners are at the far end
    assert score.games == [ScorePair(near=0, far=21)] and score.server == "far"
    assert result.steps[-1].change_ends and not result.steps[-1].ends_swapped
    assert result.steps[-1].score_after == ScorePair(near=21, far=0)  # as it was played

    result = play(game_one + ["far"] * 21, best_of=3, auto_change_ends=True)
    assert result.score.match_winner == "far"
    assert result.score.games_won == ScorePair(near=0, far=2)
    assert result.score.games == [ScorePair(near=0, far=21), ScorePair(near=0, far=21)]
    assert all(step.ends_swapped for step in result.steps[21:])
    # Without the setting the same rallies are one game each, as before 1.7.
    plain = play(game_one + ["far"] * 21, best_of=3).score
    assert plain.games_won == ScorePair(near=1, far=1) and not plain.ends_swapped
    assert plain.change_ends  # the notice still shows


def test_ends_change_at_11_in_the_deciding_and_the_only_game() -> None:
    result = play(["near"] * 11 + ["far"], auto_change_ends=True)
    assert result.steps[10].score_after == ScorePair(near=11, far=0)
    assert result.steps[10].change_ends and result.steps[11].ends_swapped
    assert result.steps[11].score_before == ScorePair(near=0, far=11)
    # The same people led 11-0 and now stand at the far end; the far end won the next rally.
    assert result.score.near == 0 and result.score.far == 12 and result.score.ends_swapped
    assert result.score.server == "far" and not result.score.change_ends

    at_11 = play(["near"] * 11, auto_change_ends=True).score
    assert at_11.change_ends and at_11.interval and (at_11.near, at_11.far) == (0, 11)
    assert at_11.server == "far" and at_11.service_court == "left"  # 11 is odd

    decider = ["near"] * 21 + ["near"] * 21 + ["near"] * 11  # game 2 goes to the other side
    score = play(decider, best_of=3, auto_change_ends=True).score
    # Ends changed after game 1, after game 2 and at 11 in game 3: three times.
    assert score.game == 3 and score.ends_swapped
    assert (score.near, score.far) == (0, 11)
    assert score.games_won == ScorePair(near=1, far=1)
    # Not at 11 in game 1 or 2 of a best of three.
    assert not play(["near"] * 11, best_of=3, auto_change_ends=True).score.ends_swapped
    # Joined past 11: the change at 11 has already happened.
    late = play(["near"], ScorePair(near=12, far=3), auto_change_ends=True).score
    assert not late.ends_swapped


def test_a_change_of_ends_by_hand() -> None:
    # Automatic changes off: the referee marks the change after game 1 (step 21).
    rallies = ["near"] * 21 + [None] + ["far"] * 21
    score = play(rallies, best_of=3, swaps={21}).score
    assert score.match_winner == "far" and score.games_won == ScorePair(near=0, far=2)
    # The players did not change: a swap by hand cancels the automatic one.
    stayed = play(rallies, best_of=3, auto_change_ends=True, swaps={21}).score
    assert stayed.games_won == ScorePair(near=1, far=1)
    one_game = play(rallies[:22], best_of=3, auto_change_ends=True, swaps={21}).score
    assert not one_game.ends_swapped and one_game.games_won == ScorePair(near=1, far=0)
    # They changed late, two rallies into game 2 (the automatic change is off).
    late = play(["near"] * 21 + ["near", "near", None, "far"], best_of=3, swaps={23})
    assert (late.score.near, late.score.far) == (0, 3) and late.score.ends_swapped
    assert late.score.games == [ScorePair(near=0, far=21)]
    # A change by hand answers the notice and plays no point.
    answered = play(["near"] * 21 + [None], best_of=3, swaps={21}).score
    assert not answered.change_ends and answered.interval and answered.server == "far"
    # After the match nothing changes.
    done = play(["near"] * 21 + [None], swaps={21}).score
    assert done.match_winner == "near" and not done.ends_swapped


def test_a_concession_and_joined_games_keep_their_side_across_a_change() -> None:
    games = ScorePair(near=1, far=0)
    score = play(["far"] * 21, best_of=3, start_games=games, auto_change_ends=True).score
    # 1-1 in games; the side that held the first game is now at the far end.
    assert score.games_won == ScorePair(near=1, far=1) and score.game == 3
    assert score.ends_swapped
    conceded = play(["near"] * 21 + [None], best_of=3, auto_change_ends=True,
                    concessions={21: "near"}).score  # fmt: skip
    assert conceded.match_winner == "near" and conceded.games_won == ScorePair(near=0, far=1)


def test_doubles_slots_cross_with_the_players_at_11() -> None:
    kwargs = {"first_server_id": "near_1", "first_receiver_id": "far_1",
              "auto_change_ends": True}  # fmt: skip
    before = play(["near"] * 10, **kwargs).score
    assert (before.server_id, before.receiver_id) == ("near_1", "far_1")
    after = play(["near"] * 11, **kwargs).score
    # The same person serves on from the far end, under the slot with the same number, at
    # 11 (odd): from the left court, to the partner who was not receiving at 10-0.
    assert (after.server, after.server_id, after.service_court) == ("far", "far_1", "left")
    assert after.receiver_id == "near_2"
    plain = play(["near"] * 11, first_server_id="near_1", first_receiver_id="far_1").score
    assert (plain.server_id, plain.receiver_id) == ("near_1", "far_2")  # mirrored above


def test_a_later_game_is_named_at_the_ends_the_pairs_stand_at() -> None:
    from shuttlesense.schema import GameService

    named = [GameService(game=2, server_id="far_2", receiver_id="near_1")]
    score = play(["near"] * 21, best_of=3, first_server_id="near_1", first_receiver_id="far_1",
                 game_service=named, auto_change_ends=True).score  # fmt: skip
    # The game winners crossed to the far end and serve first from there.
    assert (score.server, score.server_id, score.receiver_id) == ("far", "far_2", "near_1")
    wrong = [GameService(game=2, server_id="near_2", receiver_id="far_1")]
    score = play(["near"] * 21, best_of=3, first_server_id="near_1", first_receiver_id="far_1",
                 game_service=wrong, auto_change_ends=True).score  # fmt: skip
    assert score.server_id is None  # the losers cannot serve first: ignored
