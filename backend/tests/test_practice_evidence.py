import pytest

from shuttlesense.practice.evidence import SelectedPlayerTracker, assess_attempt
from shuttlesense.schema import Player


def person(x=0, confidence=0.9):
    points = [(0.0, 0.0, 0.0)] * 17
    points[0] = (5.0, 4.0, confidence)
    points[6] = (5.0, 8.0, confidence)
    points[8] = (6.0, 6.0, confidence)
    points[10] = (7.0, 3.0, confidence)
    return Player(bbox=(x, 0, 10, 20), keypoints=points, score=confidence)


def test_marked_attempt_records_image_evidence_without_contact_claim():
    attempt = assess_attempt(person(), "clear", "right", 1.25)
    assert [o.status for o in attempt.observations] == ["observed", "observed"]
    assert attempt.observations[0].value == pytest.approx(0.05)
    assert all(o.provenance == "user_marked" for o in attempt.observations)
    assert "not verified" in attempt.limitation


def test_missing_or_low_confidence_joints_are_unavailable():
    for target in (None, person(confidence=0.2)):
        result = assess_attempt(target, "smash", "right", 0)
        assert all(o.status == "unavailable" and o.value is None for o in result.observations)


def test_invalid_attempt_timestamp_rejected():
    with pytest.raises(ValueError):
        assess_attempt(person(), "drop", "left", float("nan"))


def test_ambiguous_track_stops_and_does_not_reacquire():
    track = SelectedPlayerTracker((0, 0, 10, 20))
    assert track.update([person(0), person(0.1)]) is None
    assert track.lost
    assert track.update([person(0)]) is None


def test_selected_track_is_not_reassigned_after_loss():
    track = SelectedPlayerTracker((0, 0, 10, 20))
    assert track.update([person(0)]) is not None
    assert track.update([person(30)]) is None
    assert track.update([person(0)]) is None


def test_overlapping_player_stops_attribution_after_initial_confirmation():
    track = SelectedPlayerTracker((0, 0, 10, 20))
    assert track.update([person(0), person(8)]) is not None
    assert track.update([person(0), person(8)]) is None
    assert track.lost
