from __future__ import annotations

import numpy as np

from shuttlesense.court.lines import play_bounds
from shuttlesense.referee.linecalls import call_landing
from shuttlesense.referee.rally import rally_winner, segment_rallies
from shuttlesense.referee.scoring import apply_rallies, game_winner
from shuttlesense.schema import Landing, Rally, ScorePair

CFG = {"lost_frames_end": 10, "stationary_frames_end": 5}
SIZE = (5.18, 13.40)


def moving(n: int) -> np.ndarray:
    """A shuttle that keeps moving 10 px per frame."""
    return np.array([[100.0 + 10 * (i % 40), 200.0 + 5 * (i % 7)] for i in range(n)])


def test_two_rallies_separated_by_pause() -> None:
    n = 120
    xy = moving(n)
    visible = np.ones(n, dtype=int)
    visible[:5] = 0  # nothing in play before the first serve
    visible[40:70] = 0  # shuttle gone for 30 frames between rallies
    segs = segment_rallies(visible, xy, [5, 20, 35, 75, 90], CFG)
    assert [(s.start, s.end, s.closed) for s in segs] == [(5, 39, True), (75, 119, False)]
    assert segs[0].landing_frame is None  # lost, not seen landing


def test_rally_ends_when_shuttle_stationary() -> None:
    n = 80
    xy = moving(n)
    xy[30:] = [400.0, 600.0]  # lands at frame 30 and stays
    segs = segment_rallies(np.ones(n, dtype=int), xy, [2, 15], CFG)
    assert len(segs) == 1 and segs[0].closed
    assert segs[0].end == 30 and segs[0].landing_frame == 30


def test_clip_starting_mid_rally() -> None:
    n = 60
    segs = segment_rallies(np.ones(n, dtype=int), moving(n), [4, 20], CFG)
    assert segs[0].start == 0 and not segs[0].closed and segs[0].end == n - 1
    no_play = np.zeros(n, dtype=int)
    no_play[4:] = 1
    assert segment_rallies(no_play, moving(n), [4], CFG)[0].start == 4


def test_landing_frame_is_after_last_hit() -> None:
    n = 80
    xy = moving(n)
    xy[10:16] = [300.0, 300.0]  # a false "rest" just before another hit: not a landing
    xy[50:] = [500.0, 650.0]
    segs = segment_rallies(np.ones(n, dtype=int), xy, [2, 18, 35], CFG)
    assert len(segs) == 1
    assert segs[0].landing_frame == 50


def landing_call(point: np.ndarray, size: tuple[float, float], band: float) -> tuple[bool, float]:
    call, _, confidence, _ = call_landing(point, play_bounds("singles", size), band)
    return call == "in", confidence


def test_inside_court_is_in() -> None:
    inside, conf = landing_call(np.array([2.5, 10.0]), SIZE, 0.05)
    assert inside and conf == 1.0
    out, conf = landing_call(np.array([6.0, 10.0]), SIZE, 0.05)
    assert not out and conf == 1.0


def test_close_to_line_is_uncertain() -> None:
    inside, conf = landing_call(np.array([5.16, 10.0]), SIZE, 0.05)
    assert inside and conf < 0.5
    landing = Landing(x_m=5.16, y_m=10.0, in_court=inside, confidence=conf)
    assert rally_winner(landing, "near", 6.7) is None


def test_in_shot_wins_rally() -> None:
    far_half = Landing(x_m=2.0, y_m=11.0, in_court=True, confidence=0.9)
    assert rally_winner(far_half, "near", 6.7) == "near"
    near_half = Landing(x_m=2.0, y_m=3.0, in_court=True, confidence=0.9)
    assert rally_winner(near_half, "far", 6.7) == "far"


def test_out_shot_loses_rally() -> None:
    long = Landing(x_m=2.0, y_m=14.2, in_court=False, confidence=0.9)
    assert rally_winner(long, "near", 6.7) == "far"
    wide = Landing(x_m=-0.6, y_m=2.0, in_court=False, confidence=0.9)
    assert rally_winner(wide, "far", 6.7) == "near"


def test_out_on_the_last_hitters_own_half_is_left_to_the_referee() -> None:
    # Far is the last detected hitter and the shuttle is out behind far's own baseline:
    # a mishit, or near's reply was missed and near hit it long. Opposite points: no guess.
    long = Landing(x_m=2.0, y_m=14.2, in_court=False, confidence=0.9)
    assert rally_winner(long, "far", 6.7) is None
    assert rally_winner(long, None, 6.7) is None
    # In calls do not depend on who was seen hitting.
    assert rally_winner(Landing(x_m=2.0, y_m=11.0, in_court=True, confidence=0.9), "far", 6.7) == (
        "near"
    )


def _rallies(winners: list[str | None]) -> list[Rally]:
    return [Rally(index=i, start_frame=i, end_frame=i, winner=w) for i, w in enumerate(winners)]


def test_score_sequence() -> None:
    rallies = _rallies(["near", "near", None, "far", "near", "far", "far", "near", "far", "far"])
    final = apply_rallies(rallies)
    assert [(r.score_after.near, r.score_after.far) for r in rallies] == [
        (1, 0), (2, 0), (2, 0), (2, 1), (3, 1), (3, 2), (3, 3), (4, 3), (4, 4), (4, 5),
    ]  # fmt: skip
    assert (final.near, final.far) == (4, 5)
    final = apply_rallies(_rallies(["far"]), ScorePair(near=10, far=12))
    assert (final.near, final.far) == (10, 13)


def test_deuce_to_30() -> None:
    rallies = _rallies(["near", "far"] * 9 + ["far"])
    final = apply_rallies(rallies, ScorePair(near=20, far=20))
    assert (final.near, final.far) == (29, 30) and game_winner(29, 30) == "far"
    assert final.match_winner == "far"
    rallies = _rallies(["near", "near", "far"])
    final = apply_rallies(rallies, ScorePair(near=20, far=19))
    assert (final.near, final.far) == (21, 19)
    assert rallies[1].score_after is None and rallies[2].score_after is None


def test_stage_on_golden_record() -> None:
    from shuttlesense.fake import load_golden
    from shuttlesense.referee import run as referee_run
    from shuttlesense.stage import StageContext

    record = load_golden()
    record.rallies, record.score = [], None
    ctx = StageContext(video_path=None, out_dir=None, config={"start_score": {"near": 3, "far": 4}})
    out = referee_run(record, ctx)
    assert len(out.rallies) == 1 and out.rallies[0].stroke_count == 3
    assert all(h.rally_index == 0 for h in out.hits)
    assert out.frames[10].rally_state == "in_play"
    assert out.score.near + out.score.far >= 7


def test_unobserved_frames_do_not_close_a_rally() -> None:

    visible = np.array([True, False, False, False, True])
    xy = np.array([[0, 0], [0, 0], [0, 0], [0, 0], [20, 0]])
    cfg = {"lost_frames_end": 3, "stationary_frames_end": 3}
    assert segment_rallies(visible, xy, [0], cfg)[0].closed
    assert not segment_rallies(visible, xy, [0], cfg, unobserved={2})[0].closed


def test_a_change_of_ends_by_hand_is_a_decision_that_undo_takes_back() -> None:
    from datetime import UTC, datetime

    from shuttlesense.fake import load_golden
    from shuttlesense.referee.scoring import apply_corrections, undo_last_decision
    from shuttlesense.render.overlays import score_at
    from shuttlesense.schema import Score, ScoreCorrection

    record = load_golden()
    record.rallies = [
        Rally(index=i, start_frame=10 * i, end_frame=10 * i + 5, winner="near") for i in range(4)
    ]
    record.line_calls = []
    record.score = Score()
    swap = ScoreCorrection(rally_index=2, winner_before=None, winner_after=None,
                           at=datetime.now(UTC), kind="ends", frame=17)  # fmt: skip
    apply_corrections(record, [swap])
    # Two points at the near end, the players cross, two more points at the near end: 2-2.
    assert (record.score.near, record.score.far) == (2, 2) and record.score.ends_swapped
    assert [r.ends_swapped for r in record.rallies] == [False, False, True, True]
    assert record.rallies[2].score_after == ScorePair(near=1, far=2)
    assert record.score.corrections == [swap]
    # The score shown at a frame follows the players too.
    assert score_at(record, 16) == (2, 0)
    assert score_at(record, 17) == (0, 2)  # from the frame of the change
    assert score_at(record, 26) == (1, 2)
    assert undo_last_decision(record) == []
    assert (record.score.near, record.score.far) == (4, 0) and not record.score.ends_swapped
    assert not any(r.ends_swapped for r in record.rallies)


def test_the_overlay_score_turns_after_a_change_by_rule() -> None:
    from shuttlesense.fake import load_golden
    from shuttlesense.render.overlays import score_at
    from shuttlesense.schema import Score

    record = load_golden()
    record.rallies = [
        Rally(index=i, start_frame=10 * i, end_frame=10 * i + 5, winner="near") for i in range(3)
    ]
    record.score = Score()
    record.score = apply_rallies(record.rallies, ScorePair(near=9, far=4), auto_change_ends=True)
    assert [r.change_ends for r in record.rallies] == [False, True, False]
    assert score_at(record, 4) == (9, 4)
    assert score_at(record, 6) == (10, 4)
    assert score_at(record, 16) == (4, 11)  # 11-4 as played, seen from the new ends
    assert score_at(record, 26) == (5, 11)
    assert (record.score.near, record.score.far) == (5, 11)
