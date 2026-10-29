from __future__ import annotations

import numpy as np
import pytest

from shuttlesense.court import compute_homography, court_corners_m, image_to_court, validate_corners

# A trapezoid like a court seen from behind the baseline: near side wider than far side.
CORNERS = [[200.0, 650.0], [1080.0, 650.0], [880.0, 200.0], [400.0, 200.0]]


def test_corners_map_to_court_corners() -> None:
    h = compute_homography(CORNERS)
    mapped = image_to_court(h, np.array(CORNERS))
    np.testing.assert_allclose(mapped, court_corners_m(), atol=1e-3)


def test_image_center_line_maps_to_court_center_line() -> None:
    h = compute_homography(CORNERS)
    near_mid, far_mid = [640.0, 650.0], [640.0, 200.0]
    mapped = image_to_court(h, np.array([near_mid, far_mid]))
    np.testing.assert_allclose(mapped[:, 0], [2.59, 2.59], atol=1e-3)


@pytest.mark.parametrize(
    "corners",
    [
        CORNERS[:3],  # too few
        [CORNERS[0], CORNERS[2], CORNERS[1], CORNERS[3]],  # self-intersecting order
    ],
)
def test_invalid_corners_rejected(corners: list[list[float]]) -> None:
    with pytest.raises(ValueError):
        validate_corners(corners)
