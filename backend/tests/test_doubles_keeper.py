"""Keeping all four doubles players on the court plane (D66)."""

from __future__ import annotations

import numpy as np

from shuttlesense.court import compute_homography, court_to_image
from shuttlesense.pose.doubles_keeper import DoublesSlotKeeper, keeper_config, with_doubles_keeper
from shuttlesense.pose.player_tracker import CourtPlayerTracker
from shuttlesense.schema import COURT_SIZE_M, Player, Players

H = compute_homography([[212, 650], [1068, 650], [880, 210], [400, 210]])
FRAME = np.zeros((720, 1280, 3), dtype=np.uint8)


def person(x: float, y: float, height: float = 150.0) -> Player:
    px, py = court_to_image(H, np.array([[x, y]]))[0]
    kps = [(0.0, 0.0, 0.0)] * 15 + [(float(px), float(py), 0.9)] * 2
    return Player(bbox=(float(px) - 30, float(py) - height, 60, height), keypoints=kps,
                  score=0.9)  # fmt: skip


def update(tracker, people: list[Player]) -> Players:
    return tracker.update(people, frame_height=720, homography=H, frame=FRAME)


class Scripted:
    """A stand-in for CourtPlayerTracker that emits whatever the test says."""

    def __init__(self) -> None:
        self.court, self.court_size = "doubles", COURT_SIZE_M
        self.slots = dict.fromkeys(("near", "far", "near_2", "far_2"))
        self.view_valid = True
        self.next = Players()

    def update(self, people, **_kw) -> Players:
        return self.next


def keeper(**overrides) -> tuple[DoublesSlotKeeper, Scripted]:
    inner = Scripted()
    return DoublesSlotKeeper(inner, {**keeper_config(None), **overrides}), inner


def test_singles_and_a_disabled_keeper_leave_the_tracker_alone() -> None:
    singles = CourtPlayerTracker({}, "singles", COURT_SIZE_M)
    assert with_doubles_keeper(singles, {}) is singles
    doubles = CourtPlayerTracker({}, "doubles", COURT_SIZE_M)
    assert with_doubles_keeper(doubles, {"doubles_keeper": {"enabled": False}}) is doubles
    assert isinstance(with_doubles_keeper(doubles, {}), DoublesSlotKeeper)


def test_the_wrapped_tracker_state_is_shared() -> None:
    inner = CourtPlayerTracker({}, "doubles", COURT_SIZE_M)
    k = with_doubles_keeper(inner, {})
    k.watch_outside_tracking = True  # Watch sets this on the tracker it was given
    assert inner.watch_outside_tracking and k.slots is inner.slots and k.court == "doubles"


def test_a_partner_lost_past_the_tracker_gap_comes_back() -> None:
    inner = CourtPlayerTracker({"confirmation_frames": 1}, "doubles", COURT_SIZE_M)
    k = with_doubles_keeper(inner, {})
    a, b, c, d = person(1.2, 3), person(4.0, 3), person(1.2, 10), person(4.0, 10)
    first = update(k, [a, b, c, d])
    assert None not in (first.near, first.near_2, first.far, first.far_2)
    for _ in range(120):  # near_2 hidden for 4 s: the tracker gives up on it after 90 frames
        update(k, [a, c, d])
    back = person(3.2, 3.5)  # 0.9 m from where they were last seen
    assert inner.slots["near_2"].missing > inner.max_missing
    assert update(k, [a, back, c, d]).near_2 == back


def test_a_slot_lost_for_good_re_seeds_from_the_court_after_a_few_frames() -> None:
    k, inner = keeper(max_coast_frames=10)
    k.keep["near_2"].pos, k.keep["near_2"].missing = np.array([4.0, 3.0]), 50
    newcomer, partner = person(2.5, 1.0), person(1.0, 5.0)
    inner.next = Players(near=partner)
    seen = [update(k, [partner, newcomer]).near_2 for _ in range(3)]
    assert seen == [None, None, newcomer]


def test_a_slot_never_seen_is_left_to_the_tracker() -> None:
    k, inner = keeper()
    newcomer = person(2.5, 1.0)
    assert [update(k, [newcomer]).near for _ in range(5)] == [None] * 5


def test_officials_outside_the_court_and_odd_sizes_never_re_seed() -> None:
    k, inner = keeper(max_coast_frames=0)
    k.keep["near"].pos = k.keep["near_2"].pos = np.array([2.5, 3.0])
    k.keep["near"].missing = k.keep["near_2"].missing = 1
    official = person(-1.5, 6.0)  # beside the court, past the side margin
    ball_kid = person(2.5, 2.0, height=30.0)  # far too small for a person standing there
    for _ in range(5):
        out = update(k, [official, ball_kid])
        assert out.near is None and out.near_2 is None


def test_a_filled_slot_never_duplicates_a_tracked_player() -> None:
    k, inner = keeper()
    a = person(1.2, 3)
    k.keep["near_2"].pos = np.array([1.4, 3.0])  # predicted right next to a
    inner.next = Players(near=a)
    out = update(k, [a, a.model_copy()])  # the same person, twice
    assert out.near == a and out.near_2 is None


def test_partners_handed_back_the_wrong_way_round_are_swapped() -> None:
    k, inner = keeper()
    k.keep["near"].pos, k.keep["near_2"].pos = np.array([1.0, 3.0]), np.array([4.0, 3.0])
    left, right = person(1.1, 3.0), person(3.9, 3.0)
    inner.next = Players(near=right, near_2=left)  # the tracker swapped them
    first = update(k, [left, right])
    assert first.near == right  # one frame is not enough
    second = update(k, [left, right])
    assert second.near == left and second.near_2 == right
    # The pairing stays swapped while the tracker keeps its (wrong) identities.
    assert update(k, [left, right]).near == left


def test_partners_side_by_side_are_not_swapped() -> None:
    k, inner = keeper()
    k.keep["near"].pos, k.keep["near_2"].pos = np.array([2.4, 3.0]), np.array([2.8, 3.0])
    a, b = person(2.4, 3.0), person(2.8, 3.0)
    inner.next = Players(near=b, near_2=a)
    for _ in range(4):
        assert update(k, [a, b]).near == b
