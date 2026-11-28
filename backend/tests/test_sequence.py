"""Rally winners checked against the service court of each clear serve (D65)."""

from __future__ import annotations

from shuttlesense.court import compute_homography
from shuttlesense.referee.rally import referee_review
from shuttlesense.referee.sequence import Step, decodable, decode, serve_parity
from shuttlesense.schema import ClipRecord, Court, CourtPositions, Frame, Hit, Rally, ScorePair

OPEN = {None: 0.0, "near": 1.0, "far": 1.0}
START = ScorePair()


def _pinned(side: str, parity: int | None = None) -> Step:
    return Step(options={side: 0.0}, served=(side, parity) if parity is not None else None)


def test_two_serves_from_the_wrong_court_fill_the_rally_nobody_called() -> None:
    # Near wins all three; the first is uncalled. Near then serves at 2 (right) and 3 (left).
    steps = [Step(options=OPEN), _pinned("near", 0), _pinned("near", 1)]
    assert decode(steps, START) == ["near", "near", "near"]


def test_one_serve_is_not_enough_to_score_a_rally() -> None:
    steps = [Step(options=OPEN), _pinned("near", 0)]
    assert decode(steps, START) == [None, "near"]


def test_two_uncalled_rallies_either_of_which_fits_stay_unscored() -> None:
    steps = [Step(options=OPEN), Step(options=OPEN), _pinned("near", 0), _pinned("near", 1)]
    assert decode(steps, START)[:2] == [None, None]


def test_a_close_call_against_the_serve_courts_is_flipped() -> None:
    close = Step(options={"far": 0.0, "near": 2.5})
    steps = [close, _pinned("near", 0), _pinned("near", 1)]
    assert decode(steps, START)[0] == "near"


def test_a_certain_call_never_changes() -> None:
    steps = [_pinned("far"), _pinned("near", 0), _pinned("near", 1)]
    assert decode(steps, START) == ["far", "near", "near"]


def test_serve_courts_that_agree_change_nothing() -> None:
    steps = [Step(options=OPEN), _pinned("near", 1), _pinned("near", 0)]
    assert decode(steps, START) == [None, "near", "near"]


def test_the_start_score_sets_the_parity() -> None:
    # From 1-0, near serving at 2 then 3: the first rally (uncalled) went to far.
    steps = [Step(options=OPEN), _pinned("near", 0), _pinned("near", 1)]
    assert decode(steps, ScorePair(near=1, far=0))[0] is None
    steps = [Step(options=OPEN), _pinned("far", 0), _pinned("far", 1)]
    assert decode(steps, ScorePair(near=1, far=0))[0] == "far"


def test_only_rallies_before_a_possible_game_end_are_followed() -> None:
    assert decodable(50, START) == 20
    assert decodable(5, START) == 5
    assert decodable(10, ScorePair(near=18, far=3)) == 2


def _record(x: float, side: str) -> tuple[ClipRecord, Hit]:
    positions = CourtPositions(**{side: (x, 2.0 if side == "near" else 11.0)})
    record = ClipRecord(clip_id="c", fps=30, width=1280, height=720, num_frames=1,
                        frames=[Frame(frame=0, court_positions=positions)])  # fmt: skip
    return record, Hit(id=0, frame=0, time_s=0, player=side)


def test_the_service_court_from_the_servers_feet() -> None:
    # Facing the net, near's right is +x and far's right is -x.
    assert serve_parity(*_record(4.0, "near"), 0.3) == 0
    assert serve_parity(*_record(1.0, "near"), 0.3) == 1
    assert serve_parity(*_record(1.0, "far"), 0.3) == 0
    assert serve_parity(*_record(2.6, "far"), 0.3) is None  # on the centre line


def test_a_rally_scored_from_the_serve_courts_says_so() -> None:
    corners = [(300.0, 650.0), (980.0, 650.0), (820.0, 250.0), (460.0, 250.0)]
    record = ClipRecord(clip_id="c", fps=30, width=1280, height=720, num_frames=1,
                        frames=[Frame(frame=0)],
                        court=Court(corners_px=corners,
                                    homography=compute_homography(corners).tolist()))  # fmt: skip
    rally = Rally(index=0, start_frame=0, end_frame=0, winner="near")
    record.rallies = [rally]
    assert "from where the servers stood" in (referee_review(record, rally) or "")
