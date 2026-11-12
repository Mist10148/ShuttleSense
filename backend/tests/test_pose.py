from __future__ import annotations

import numpy as np

from shuttlesense.court import compute_homography
from shuttlesense.pose.tracking import (
    PlayerTracker,
    bbox_from_keypoints,
    filter_players,
    smooth_keypoints,
)
from shuttlesense.schema import Player

CORNERS = [[212, 650], [1068, 650], [880, 210], [400, 210]]


def box(cx: float, foot: float, w: float = 60, h: float = 150, score: float = 0.9) -> Player:
    return Player(bbox=(cx - w / 2, foot - h, w, h), score=score)


def test_tracking_keeps_ids_when_players_cross() -> None:
    tracker = PlayerTracker()
    near0, far0 = tracker.update([box(500, 600), box(700, 300)])
    assert near0.bbox[0] == 470 and far0.bbox[0] == 670
    # Both drift towards the middle; far ends up lower in the image than near for a moment.
    for t in range(1, 11):
        a = box(500 + 10 * t, 600 - 32 * t)
        b = box(700 - 10 * t, 300 + 32 * t)
        near, far = tracker.update([b, a])  # detector order shuffled
        assert near is a and far is b


def test_filters_people_outside_court() -> None:
    h = compute_homography(CORNERS)
    on_court = box(640, 600, w=80, h=200)
    umpire = box(100, 400, w=90, h=220)  # far outside the sideline, larger box
    far = box(640, 260)
    kept = filter_players([umpire, on_court, far], frame_height=720, homography=h)
    assert umpire not in kept and len(kept) == 2
    stands = box(640, 50)
    assert filter_players([stands, on_court], frame_height=720) == [on_court]


def test_filter_uses_the_configured_court_size() -> None:
    from shuttlesense.court import court_to_image

    doubles = (6.10, 13.40)
    h = compute_homography(CORNERS, doubles)
    # Feet 1 m outside the doubles sideline: 7.1 m across, past singles width + 1.5 m margin.
    fx, fy = court_to_image(h, np.array([[7.1, 3.0]]))[0]
    player = box(fx, fy)
    assert filter_players([player], frame_height=720, homography=h, court_size=doubles) == [player]
    assert filter_players([player], frame_height=720, homography=h) == []


def test_hold_missing_player_for_n_frames() -> None:
    tracker = PlayerTracker(hold_frames=2, hold_decay=0.5)
    tracker.update([box(500, 600), box(700, 300)])
    near, far = tracker.update([box(505, 600)])
    assert far is not None and far.score == 0.45
    _, far = tracker.update([box(510, 600)])
    assert far is not None
    _, far = tracker.update([box(515, 600)])
    assert far is None


def test_smoothing_reduces_jitter() -> None:
    rng = np.random.default_rng(0)
    seq = [[(100 + rng.normal(0, 3), 200 + rng.normal(0, 3), 0.9)] * 17 for _ in range(40)]
    out = smooth_keypoints(seq, window=5)
    before = np.var([k[0][0] for k in seq])
    after = np.var([k[0][0] for k in out])
    assert after < before / 2
    assert all(len(k) == 17 for k in out)


def test_low_score_joints_not_smoothed_into_good_ones() -> None:
    good = [(100.0, 100.0, 0.9)] * 17
    bad = [(500.0, 500.0, 0.1)] * 17
    out = smooth_keypoints([good, bad, good], window=3, min_score=0.3)
    assert out[0][0][:2] == (100.0, 100.0)
    assert out[1][0] == (500.0, 500.0, 0.1)  # low-score joint left as is
    gap = smooth_keypoints([good, None, [(200.0, 200.0, 0.9)] * 17], window=3)
    assert gap[0][0][:2] == (100.0, 100.0) and gap[1] is None


def test_bbox_from_keypoints() -> None:
    kps = np.array([[10, 10], [30, 50], [20, 90]], float)
    assert bbox_from_keypoints(kps, np.array([0.9, 0.9, 0.9]), pad=0) == (10, 10, 20, 80)
    assert bbox_from_keypoints(kps, np.array([0.9, 0.1, 0.1])) is None


def test_keypoint_rcnn_backend_converts_detections(monkeypatch) -> None:
    import sys
    import types

    import pytest

    torch = pytest.importorskip("torch")
    from shuttlesense.pose import estimator

    seen = {}

    class FakeModel:
        def to(self, device):
            seen["device"] = device
            return self

        def eval(self):
            return self

        def __call__(self, images):
            seen["shape"] = tuple(images[0].shape)
            seen["max"] = float(images[0].max())
            kps = torch.zeros((1, 17, 3))
            kps[0, :, 0] = torch.arange(17.0) + 10
            kps[0, :, 1] = 40.0
            return [
                {
                    "boxes": torch.tensor([[10.0, 20.0, 50.0, 100.0]]),
                    "scores": torch.tensor([0.9]),
                    "keypoints": kps,
                    "keypoints_scores": torch.full((1, 17), 10.0),
                }
            ]

    detection = types.ModuleType("torchvision.models.detection")
    detection.KeypointRCNN_ResNet50_FPN_Weights = types.SimpleNamespace(DEFAULT="default")
    detection.keypointrcnn_resnet50_fpn = lambda weights: FakeModel()
    for name in ("torchvision", "torchvision.models"):
        monkeypatch.setitem(sys.modules, name, types.ModuleType(name))
    monkeypatch.setitem(sys.modules, "torchvision.models.detection", detection)
    monkeypatch.setattr(estimator, "_MODELS", {})

    detect = estimator.load_detector("keypoint_rcnn", "balanced", "cpu")
    frame = np.zeros((120, 160, 3), np.uint8)
    frame[..., 0] = 255  # pure blue in BGR
    (person,) = detect(frame)
    assert seen == {"device": "cpu", "shape": (3, 120, 160), "max": 1.0}
    assert person.bbox == (10.0, 20.0, 40.0, 80.0)
    assert person.score == pytest.approx(0.9)
    assert len(person.keypoints) == 17
    assert person.keypoints[3][:2] == (13.0, 40.0) and person.keypoints[3][2] > 0.99
    assert estimator.load_detector("keypoint_rcnn", "balanced", "cpu") is detect  # cached


def test_unknown_pose_backend_skips_the_stage() -> None:
    import pytest

    from shuttlesense.pose import estimator
    from shuttlesense.stage import StageSkipped

    with pytest.raises(StageSkipped):
        estimator.load_detector("openpose", "balanced", "cpu")


# Doubles (T9.3, T9.4) ------------------------------------------------------------------------


def _court_box(h, x_m: float, y_m: float, height: float = 150) -> Player:
    from shuttlesense.court import court_to_image

    fx, fy = court_to_image(h, np.array([[x_m, y_m]]))[0]
    return box(float(fx), float(fy), w=height * 0.4, h=height)


def test_doubles_tracker_keeps_partner_slots_when_they_cross() -> None:
    from shuttlesense.pose.tracking import DoublesTracker

    h = compute_homography(CORNERS)
    tracker = DoublesTracker()
    first = [_court_box(h, 1.5, 3.0), _court_box(h, 3.7, 3.0), _court_box(h, 1.5, 10.0),
             _court_box(h, 3.7, 10.0)]  # fmt: skip
    slots = tracker.update(first, frame_height=720, homography=h)
    assert slots["near_1"] is first[0] and slots["near_2"] is first[1]  # left is _1
    assert slots["far_1"] is first[2] and slots["far_2"] is first[3]
    # The near partners swap sides in small steps (front/back rotation).
    for t in range(1, 11):
        a = _court_box(h, 1.5 + 0.22 * t, 3.0 + 0.1 * t)
        b = _court_box(h, 3.7 - 0.22 * t, 3.0 - 0.1 * t)
        far = [_court_box(h, 1.5, 10.0), _court_box(h, 3.7, 10.0)]
        slots = tracker.update([b, *far, a], frame_height=720, homography=h)
        assert slots["near_1"] is a and slots["near_2"] is b
        assert slots["far_1"] is far[0]


def test_doubles_tracker_never_moves_a_slot_across_the_net() -> None:
    from shuttlesense.pose.tracking import DoublesTracker

    h = compute_homography(CORNERS)
    tracker = DoublesTracker(hold_frames=1)
    tracker.update([_court_box(h, 2.0, 3.0), _court_box(h, 2.0, 10.0)], frame_height=720,
                   homography=h)  # fmt: skip
    # Only far players are seen: the near slot holds, then empties; it is never filled from far.
    for _ in range(3):
        slots = tracker.update([_court_box(h, 2.0, 10.0), _court_box(h, 3.5, 9.0)],
                               frame_height=720, homography=h)  # fmt: skip
    assert slots["near_1"] is None and slots["near_2"] is None
    assert slots["far_1"] is not None and slots["far_2"] is not None


def test_doubles_tracker_holds_a_hidden_partner() -> None:
    from shuttlesense.pose.tracking import DoublesTracker

    h = compute_homography(CORNERS)
    tracker = DoublesTracker(hold_frames=4, hold_decay=0.5)
    a, b = _court_box(h, 1.5, 3.0), _court_box(h, 3.7, 3.0)
    tracker.update([a, b], frame_height=720, homography=h)
    for _ in range(4):
        slots = tracker.update([_court_box(h, 3.7, 3.0)], frame_height=720, homography=h)
    assert slots["near_1"] is not None and slots["near_1"].score < a.score
    assert slots["near_2"].bbox == b.bbox


def test_shirt_colour_keeps_partners_apart_when_they_overlap() -> None:
    """Position alone would swap the partners here; their shirts keep the slots."""
    from shuttlesense.pose.tracking import DoublesTracker

    h = compute_homography(CORNERS)
    frame = np.zeros((720, 1280, 3), np.uint8)

    def paint(p: Player, bgr: tuple[int, int, int]) -> None:
        x, y, w, hh = (int(v) for v in p.bbox)
        frame[y : y + hh, x : x + w] = bgr

    tracker = DoublesTracker(close_m=0.8)
    red, blue = _court_box(h, 2.3, 3.0), _court_box(h, 2.9, 3.0)
    for _ in range(5):  # learn the shirts while the partners stand apart
        frame[:] = 0
        paint(red, (0, 0, 255))
        paint(blue, (255, 0, 0))
        slots = tracker.update([red, blue], frame_height=720, homography=h, frame=frame)
    assert slots["near_1"] is red
    # They pass each other: red is now where blue was, and the other way round.
    red2, blue2 = _court_box(h, 2.8, 3.0), _court_box(h, 2.4, 3.0)
    frame[:] = 0
    paint(red2, (0, 0, 255))
    paint(blue2, (255, 0, 0))
    slots = tracker.update([blue2, red2], frame_height=720, homography=h, frame=frame)
    assert slots["near_1"] is red2 and slots["near_2"] is blue2


def test_doubles_tracker_without_a_court_splits_by_image_height() -> None:
    from shuttlesense.pose.tracking import DoublesTracker

    tracker = DoublesTracker()
    people = [box(400, 650), box(800, 640), box(500, 300), box(760, 310)]
    slots = tracker.update(people, frame_height=720)
    assert {id(slots["near_1"]), id(slots["near_2"])} == {id(people[0]), id(people[1])}
    assert {id(slots["far_1"]), id(slots["far_2"])} == {id(people[2]), id(people[3])}


def test_make_tracker_follows_the_court() -> None:
    from shuttlesense.pose.tracking import DoublesTracker, make_tracker, track_players

    assert isinstance(make_tracker({}, "singles"), PlayerTracker)
    tracker = make_tracker({"appearance_weight": 1.0}, "doubles")
    assert isinstance(tracker, DoublesTracker) and tracker.appearance_weight == 1.0
    players = track_players(tracker, [box(500, 600), box(700, 300)], frame_height=720)
    assert players.near is not None and players.far is not None and players.near_2 is None
