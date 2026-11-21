import numpy as np

from shuttlesense.fake import load_golden
from shuttlesense.render.overlays import LAYERS, RenderState, draw_trail
from shuttlesense.render.style import SPEED_COLORS, speed_color
from shuttlesense.schema import Frame, Shuttle


def test_speed_bands_and_unavailable():
    assert [speed_color(v) for v in (0, 30, 60, 100)] == list(SPEED_COLORS)
    assert [speed_color(v) for v in (29.9, 59.9, 99.9, 450)] == list(SPEED_COLORS)
    assert all(speed_color(v) is None for v in (None, -1, float("nan"), float("inf"), 451))


def test_trail_follows_each_visible_sample():
    record = load_golden()
    record.frames = [
        Frame(frame=i, shuttle=Shuttle(visible=1, x=15 + 18 * i, y=20), shuttle_speed_kmh=v)
        for i, v in enumerate((0, 30, None, 60, 100))
    ]
    img = np.zeros((40, 110, 3), np.uint8)
    neutral = img.copy()
    state = RenderState()
    draw_trail(neutral, record, 4, state)
    LAYERS["trail"](img, record, 4, state)
    for i, frame in enumerate(record.frames):
        color = speed_color(frame.shuttle_speed_kmh)
        x = 15 + 18 * i
        if color is None:
            assert np.array_equal(img[:, x - 5 : x + 6], neutral[:, x - 5 : x + 6])
        else:
            fade = 1 - 0.8 * (4 - i) / 12
            assert tuple(img[20, x]) == tuple(round(c * fade) for c in color)
