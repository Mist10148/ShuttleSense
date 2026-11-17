import cv2
import numpy as np
import pytest

from shuttlesense.court.detect import detect_corners


@pytest.mark.parametrize("doubles", [False, True])
def test_finds_projected_singles_reference_court(doubles):
    image = np.full((720, 1280, 3), (40, 100, 40), np.uint8)
    expected = np.float32([[260, 620], [1020, 620], [810, 180], [470, 180]])
    transform = cv2.getPerspectiveTransform(np.float32([[0, 0], [1, 0], [1, 1], [0, 1]]), expected)
    segments = [
        ((0, 0), (1, 0)),
        ((1, 0), (1, 1)),
        ((1, 1), (0, 1)),
        ((0, 1), (0, 0)),
        ((0, 0.3522), (1, 0.3522)),
        ((0, 0.6478), (1, 0.6478)),
        ((0.5, 0), (0.5, 0.3522)),
        ((0.5, 0.6478), (0.5, 1)),
    ]
    if doubles:
        segments += [
            ((-0.089, 0), (-0.089, 1)),
            ((1.089, 0), (1.089, 1)),
            ((-0.089, 0.0567), (1.089, 0.0567)),
            ((-0.089, 0.9433), (1.089, 0.9433)),
        ]
    for a, b in segments:
        points = cv2.perspectiveTransform(np.float32([[a, b]]), transform)[0].astype(int)
        cv2.line(image, tuple(points[0]), tuple(points[1]), (245, 245, 245), 4)
    result = detect_corners(image)
    assert result is not None
    assert np.max(np.abs(np.asarray(result) - expected)) < 12


def test_blank_frame_returns_no_suggestion():
    assert detect_corners(np.zeros((720, 1280, 3), np.uint8)) is None


def test_rejects_background_with_reversed_court_perspective():
    # Bright background graphics can resemble a court, but a court seen from its end
    # should not be wider at the far end than the near end.
    image = np.full((720, 1280, 3), (45, 45, 45), np.uint8)
    trapezoid = np.float32([[340, 500], [940, 500], [1100, 80], [180, 80]])
    transform = cv2.getPerspectiveTransform(np.float32([[0, 0], [1, 0], [1, 1], [0, 1]]), trapezoid)
    segments = [
        ((0, 0), (1, 0)),
        ((1, 0), (1, 1)),
        ((1, 1), (0, 1)),
        ((0, 1), (0, 0)),
        ((0, 0.3522), (1, 0.3522)),
        ((0, 0.6478), (1, 0.6478)),
        ((0.5, 0), (0.5, 0.3522)),
        ((0.5, 0.6478), (0.5, 1)),
    ]
    for a, b in segments:
        points = cv2.perspectiveTransform(np.float32([[a, b]]), transform)[0].astype(int)
        cv2.line(image, tuple(points[0]), tuple(points[1]), (245, 245, 245), 4)
    assert detect_corners(image) is None


def test_rejects_strong_dark_background_edges():
    image = np.full((720, 1280, 3), 180, np.uint8)
    for y in (100, 200, 300, 400, 500):
        cv2.line(image, (100, y), (1180, y), (5, 5, 5), 4)
    for x in (200, 400, 600, 800, 1000):
        cv2.line(image, (x, 50), (x, 650), (5, 5, 5), 4)
    assert detect_corners(image) is None
