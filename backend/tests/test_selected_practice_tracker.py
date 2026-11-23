import numpy as np

from shuttlesense.practice.selected_tracker import SelectedIdentityTracker
from shuttlesense.schema import Player


def person(x, y=5):
    return Player(bbox=(x, y, 20, 40), score=0.9)


def scene(*entries):
    image = np.zeros((80, 140, 3), dtype=np.uint8)
    for player, color in entries:
        x, y, w, h = map(int, player.bbox)
        image[y : y + h, x : x + w] = color
    return image


def test_motion_does_not_require_overlapping_boxes():
    tracker = SelectedIdentityTracker((5, 5, 20, 40))
    first, moved = person(5), person(22)
    assert tracker.update([first], scene((first, (0, 0, 255)))) is first
    assert tracker.update([moved], scene((moved, (0, 0, 255)))) is moved


def test_other_player_cannot_take_the_missing_players_last_box():
    tracker = SelectedIdentityTracker((5, 5, 20, 40))
    selected, opponent = person(5), person(5)
    red, blue = (0, 0, 255), (255, 0, 0)
    assert tracker.update([selected], scene((selected, red))) is selected
    assert tracker.update([], scene()) is None
    for _ in range(3):
        assert tracker.update([opponent], scene((opponent, blue))) is None
    assert tracker.update([selected], scene((selected, red))) is None
    assert tracker.update([selected], scene((selected, red))) is selected


def test_crossing_is_unobserved_then_requires_confirmed_recovery():
    tracker = SelectedIdentityTracker((5, 5, 20, 40))
    first, apart, overlapping = person(5), person(45), person(12)
    red, blue = (0, 0, 255), (255, 0, 0)
    assert tracker.update([first, apart], scene((first, red), (apart, blue))) is first
    assert tracker.update([first, overlapping], scene((first, red), (overlapping, blue))) is None
    assert tracker.update([first, apart], scene((first, red), (apart, blue))) is None
    assert tracker.update([first, apart], scene((first, red), (apart, blue))) is first


def test_crossing_similar_clothes_cannot_transfer_identity():
    tracker = SelectedIdentityTracker((5, 5, 20, 40))
    selected, apart, overlap, wrong = person(5), person(45), person(12), person(5)
    red = (0, 0, 255)
    assert tracker.update([selected, apart], scene((selected, red), (apart, red))) is selected
    assert tracker.update([selected, overlap], scene((selected, red), (overlap, red))) is None
    for _ in range(4):
        assert tracker.update([wrong], scene((wrong, red))) is None


def test_unseen_competitor_after_overlap_does_not_trigger_recovery():
    tracker = SelectedIdentityTracker((5, 5, 20, 40))
    selected, overlap = person(5), person(12)
    red = (0, 0, 255)
    assert tracker.update([selected], scene((selected, red))) is selected
    assert tracker.update([selected, overlap], scene((selected, red), (overlap, red))) is None
    for _ in range(4):
        assert tracker.update([selected], scene((selected, red))) is None


def test_similar_competitor_is_not_adopted_after_occlusion_without_visible_crossing():
    tracker = SelectedIdentityTracker((5, 5, 20, 40))
    selected, competitor, impostor = person(5), person(45), person(5)
    red = (0, 0, 255)
    assert (
        tracker.update([selected, competitor], scene((selected, red), (competitor, red)))
        is selected
    )
    assert tracker.update([], scene()) is None
    for _ in range(3):
        assert tracker.update([impostor], scene((impostor, red))) is None


def test_recovery_is_disabled_without_appearance_or_after_long_gap():
    tracker = SelectedIdentityTracker((0, 0, 2, 2), max_gap=2)
    tiny = Player(bbox=(0, 0, 2, 2), score=0.9)
    image = np.zeros((4, 4, 3), dtype=np.uint8)
    assert tracker.update([tiny], image) is tiny
    assert tracker.appearance is None
    assert tracker.update([], image) is None
    assert tracker.update([tiny], image) is None
    assert tracker.update([tiny], image) is None
    assert tracker.update([tiny], image) is None


def test_initial_detection_miss_does_not_replace_the_selected_person():
    tracker = SelectedIdentityTracker((5, 5, 20, 40))
    selected, opponent = person(5), person(5)
    red, blue = (0, 0, 255), (255, 0, 0)
    assert tracker.update([], scene((selected, red))) is None
    assert tracker.update([opponent], scene((opponent, blue))) is None
    assert tracker.update([selected], scene((selected, red))) is None
    assert tracker.update([selected], scene((selected, red))) is selected
