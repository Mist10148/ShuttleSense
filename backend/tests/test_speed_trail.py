import cv2
import numpy as np
import pytest

from shuttlesense.fake import load_golden
from shuttlesense.render.overlays import LAYERS, RenderState
from shuttlesense.render.style import SPEED_COLORS, speed_color
from shuttlesense.schema import Frame, Rally, Shuttle


def test_speed_bands_and_unavailable():
    assert [speed_color(v) for v in (0, 30, 60, 100)] == list(SPEED_COLORS)
    assert [speed_color(v) for v in (29.9, 59.9, 99.9, 450)] == list(SPEED_COLORS)
    assert all(speed_color(v) is None for v in (None, -1, float("nan"), float("inf"), 451))


def test_trail_draws_speed_segments_with_a_hollow_current_marker():
    record = load_golden()
    record.rallies = []
    record.frames = [
        Frame(frame=i, shuttle=Shuttle(visible=1, x=15 + 20 * i, y=20), shuttle_speed_kmh=v)
        for i, v in enumerate((None, 0, 30, None, 60, 100))
    ]
    img = np.zeros((40, 130, 3), np.uint8)
    img[20, 115] = (11, 45, 70)
    LAYERS["trail"](img, record, 5, RenderState())

    green = img[20, 25]
    yellow = img[20, 45]
    neutral = img[20, 65]
    orange = img[20, 85]
    red = img[20, 105]
    assert green[1] > green[0] and green[1] > green[2]
    assert yellow[1] > yellow[0] and yellow[2] > yellow[0]
    assert neutral[0] == neutral[1] == neutral[2] > 0
    assert orange[2] > orange[1] > orange[0]
    assert red[2] > red[1] and red[2] > red[0]
    assert tuple(img[20, 115]) == (11, 45, 70)
    assert img[14, 115].min() > 180


@pytest.mark.parametrize("scale,width,wider_width", [(1.0, 1, 2), (3.0, 3, 5)])
@pytest.mark.parametrize("background", [25, 230])
def test_trail_softens_the_wider_stroke_at_frame_edges(scale, width, wider_width, background):
    record = load_golden()
    record.rallies = []
    record.frames = [
        Frame(frame=0, shuttle=Shuttle(visible=1, x=-5, y=0)),
        Frame(frame=1, shuttle=Shuttle(visible=1, x=1285, y=0), shuttle_speed_kmh=100),
        Frame(frame=2, shuttle=Shuttle(visible=0)),
    ]
    img = np.full((720, 1280, 3), background, np.uint8)
    narrow = img.copy()
    wide = img.copy()
    color = SPEED_COLORS[-1]
    cv2.line(narrow, (0, 0), (1279, 0), color, width, cv2.LINE_AA)
    cv2.line(wide, (0, 0), (1279, 0), color, wider_width, cv2.LINE_AA)
    blended = cv2.addWeighted(narrow, 0.65, wide, 0.35, 0)
    alpha = 0.85 - 0.65 / 12
    expected = cv2.addWeighted(blended, alpha, img, 1 - alpha, 0)

    LAYERS["trail"](img, record, 2, RenderState(scale=scale))

    np.testing.assert_array_equal(img, expected)


def test_trail_breaks_at_missing_samples_and_rally_boundaries():
    record = load_golden()
    record.rallies = [Rally(index=0, start_frame=0, end_frame=1, stroke_count=0)]
    record.frames = [
        Frame(frame=i, shuttle=Shuttle(visible=1, x=15 + 20 * i, y=20)) for i in range(7)
    ]
    record.frames[3].shuttle = Shuttle(visible=0)
    record.frames[6].shuttle = Shuttle(visible=0)
    img = np.zeros((40, 150, 3), np.uint8)
    LAYERS["trail"](img, record, 6, RenderState())

    assert img[20, 25].any()
    assert img[20, 105].any()
    assert not img[:, 45].any()  # new rally
    assert not img[:, 65:86].any()  # tracking gap
    assert not img[14, 115].any()  # no stale marker
