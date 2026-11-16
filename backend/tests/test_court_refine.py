"""Tapped corners snapped onto the painted court lines (court/refine.py)."""

from __future__ import annotations

import cv2
import numpy as np

from shuttlesense.court import compute_homography, image_to_court
from shuttlesense.court.refine import refine_corners, template_points

TRUE = np.float32([[260, 620], [1020, 620], [810, 180], [470, 180]])


def court_image(corners: np.ndarray = TRUE) -> np.ndarray:
    """A green floor with the singles lines painted for a court at `corners`."""
    image = np.full((720, 1280, 3), (40, 100, 40), np.uint8)
    unit = np.float32([[0, 0], [1, 0], [1, 1], [0, 1]])
    transform = cv2.getPerspectiveTransform(unit, corners)
    s = 1.98 / 13.40
    segments = [
        ((0, 0), (1, 0)),
        ((1, 0), (1, 1)),
        ((1, 1), (0, 1)),
        ((0, 1), (0, 0)),
        ((0, 0.5 - s), (1, 0.5 - s)),
        ((0, 0.5 + s), (1, 0.5 + s)),
        ((0.5, 0), (0.5, 0.5 - s)),
        ((0.5, 0.5 + s), (0.5, 1)),
    ]
    for a, b in segments:
        pts = cv2.perspectiveTransform(np.float32([[a, b]]), transform)[0]
        cv2.line(image, tuple(map(int, pts[0])), tuple(map(int, pts[1])), (245, 245, 245), 3)
    return image


def test_template_follows_the_court_dimensions() -> None:
    points = template_points()
    assert points.min() >= 0 and points.max() <= 1
    service = {round(float(y), 4) for x, y in points if 0.2 < x < 0.4 and 0.3 < y < 0.7}
    assert service == {round(0.5 - 1.98 / 13.40, 4), round(0.5 + 1.98 / 13.40, 4)}


def test_taps_a_few_pixels_off_are_moved_onto_the_lines() -> None:
    image = court_image()
    tapped = TRUE + np.float32([[5, -4], [-6, 3], [4, 5], [-3, -5]])
    refined, report = refine_corners(image, tapped)
    assert report["refined"] and report["support_after"] > report["support_before"]
    assert report["support_after"] > 0.9 and report["shift_px"] <= 12
    before = np.abs(tapped - TRUE).max()
    after = np.abs(np.asarray(refined) - TRUE).max()
    assert after < 2.0 < before
    # What it buys on the court: the far corner was 20 cm or more off, now a few cm.
    far_m = np.array([[0.0, 13.40]])
    off = lambda c: float(  # noqa: E731
        np.linalg.norm(image_to_court(compute_homography(c), TRUE[[3]]) - far_m)
    )
    assert off(tapped) > 0.15 and off(refined) < 0.06


def test_exact_taps_stay_put() -> None:
    refined, report = refine_corners(court_image(), TRUE)
    assert np.abs(np.asarray(refined) - TRUE).max() < 1.5


def test_no_markings_or_a_far_off_tap_leave_the_corners_as_given() -> None:
    blank = np.full((720, 1280, 3), (40, 100, 40), np.uint8)
    tapped = (TRUE + 3).tolist()
    refined, report = refine_corners(blank, tapped)
    assert refined == tapped and not report["refined"]
    # 40 px off: beyond what a nudge may do, and the lines there give no support.
    wild = (TRUE + np.float32([[40, 0], [40, 0], [40, 0], [40, 0]])).tolist()
    refined, report = refine_corners(court_image(), wild)
    assert refined == wild and not report["refined"]


def test_a_player_standing_on_a_line_does_not_stop_the_fit() -> None:
    image = court_image()
    cv2.rectangle(image, (560, 520), (640, 640), (30, 30, 160), -1)  # covers the near baseline
    cv2.rectangle(image, (600, 150), (640, 215), (160, 30, 30), -1)  # and the far one
    tapped = TRUE + np.float32([[4, 4], [-5, -3], [-4, 4], [5, -4]])
    refined, report = refine_corners(image, tapped)
    assert report["refined"] and np.abs(np.asarray(refined) - TRUE).max() < 2.5
