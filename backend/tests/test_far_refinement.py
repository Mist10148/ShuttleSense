"""Focused far-player recovery must respect court coordinates and locked slots."""

import numpy as np

from shuttlesense.court import compute_homography, court_to_image
from shuttlesense.pose.far_refinement import FarPlayerRefiner
from shuttlesense.pose.player_tracker import CourtPlayerTracker
from shuttlesense.schema import COURT_SIZE_M, Player

H = compute_homography([[212, 650], [1068, 650], [880, 210], [400, 210]])


def test_refines_only_after_a_locked_far_player_is_missing():
    frame = np.zeros((720, 1280, 3), dtype=np.uint16)
    frame[:, :, 0] = np.arange(1280, dtype=np.uint16)
    frame[:, :, 1] = np.arange(720, dtype=np.uint16)[:, None]
    tracker = CourtPlayerTracker({}, "doubles", COURT_SIZE_M)
    refiner = FarPlayerRefiner({"far_refinement_hold_frames": 2}, "doubles", COURT_SIZE_M)
    calls = []

    def detector(crop):
        x0, y0 = (int(v) for v in crop[0, 0, :2])
        calls.append((x0, y0))
        people = []
        for xy in ((2.0, 10.0), (2.0, 14.4), (-0.9, 10.0), (2.0, 6.72)):
            px, py = court_to_image(H, np.array([xy]))[0]
            x, y = float(px) - x0, float(py) - y0
            kps = [(0.0, 0.0, 0.0)] * 15 + [(x, y, 0.9)] * 2
            people.append(Player(bbox=(x - 15, y - 60, 30, 60), keypoints=kps, score=0.9))
        return people

    assert refiner.refine(frame, detector, tracker, [], homography=H) == []
    assert calls == []
    tracker.slots["far"].locked = True
    tracker.slots["far_2"].locked = True
    tracker.slots["far_2"].missing = 1
    result = refiner.refine(frame, detector, tracker, [], homography=H)
    assert len(result) == 2 and len(calls) == 1
    foot = result[0].keypoints[15]
    expected = court_to_image(H, np.array([[2.0, 10.0]]))[0]
    assert np.allclose(foot[:2], expected)
    tracker.slots["far_2"].missing = 0
    refiner.refine(frame, detector, tracker, [], homography=H)
    assert len(calls) == 2  # short continuation avoids alternating full-frame and crop
    refiner.refine(frame, detector, tracker, [], homography=H)
    assert len(calls) == 2
    assert refiner.refine(frame, detector, tracker, [], homography=None) == []


def test_unlocked_slots_and_old_gaps_do_not_trigger_crop():
    tracker = CourtPlayerTracker({}, "singles", COURT_SIZE_M)
    refiner = FarPlayerRefiner({"far_refinement_max_missing": 2}, "singles", COURT_SIZE_M)
    frame = np.zeros((720, 1280, 3), np.uint8)
    tracker.slots["far"].missing = 1

    def detect(_):
        raise AssertionError("unexpected crop")

    assert refiner.refine(frame, detect, tracker, [], homography=H) == []
    tracker.slots["far"].locked = True
    tracker.slots["far"].missing = 3
    assert refiner.refine(frame, detect, tracker, [], homography=H) == []
    disabled = FarPlayerRefiner({"far_refinement_enabled": False}, "singles", COURT_SIZE_M)
    tracker.slots["far"].missing = 1
    assert disabled.refine(frame, detect, tracker, [], homography=H) == []


def test_unusable_court_transform_does_not_start_an_invalid_crop():
    tracker = CourtPlayerTracker({}, "singles", COURT_SIZE_M)
    tracker.slots["far"].locked = True
    tracker.slots["far"].missing = 1
    refiner = FarPlayerRefiner({}, "singles", COURT_SIZE_M)
    frame = np.zeros((720, 1280, 3), np.uint8)
    assert refiner.refine(frame, lambda _: [], tracker, [], homography=np.zeros((3, 3))) == []


def test_crop_coordinates_return_to_full_session_scale():
    frame = np.zeros((360, 640, 3), dtype=np.uint16)
    frame[:, :, 0] = np.arange(640, dtype=np.uint16)
    frame[:, :, 1] = np.arange(360, dtype=np.uint16)[:, None]
    tracker = CourtPlayerTracker({}, "singles", COURT_SIZE_M)
    tracker.slots["far"].locked = True
    tracker.slots["far"].missing = 1
    refiner = FarPlayerRefiner({}, "singles", COURT_SIZE_M)
    expected = court_to_image(H, np.array([[2.0, 10.0]]))[0]

    def detector(crop):
        x0, y0 = (int(v) for v in crop[0, 0, :2])
        x, y = expected / 2 - np.array([x0, y0])
        kps = [(0.0, 0.0, 0.0)] * 15 + [(x, y, 0.9)] * 2
        return [Player(bbox=(x - 10, y - 30, 20, 30), keypoints=kps, score=0.9)]

    result = refiner.refine(frame, detector, tracker, [], homography=H, scale=(2, 2))
    assert len(result) == 1
    assert np.allclose(result[0].keypoints[15][:2], expected)
