from __future__ import annotations

import shutil
from pathlib import Path

import numpy as np
import pytest

from shuttlesense.render.writer import VideoWriter


def _frames(n: int, size: tuple[int, int] = (64, 48)):
    w, h = size
    for i in range(n):
        img = np.zeros((h, w, 3), dtype=np.uint8)
        img[:, : (i * 4) % w] = 200
        yield img


def _count(path: Path) -> int:
    import cv2

    cap = cv2.VideoCapture(str(path))
    n = 0
    while cap.read()[0]:
        n += 1
    cap.release()
    return n


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_writer_produces_playable_mp4(tmp_path: Path) -> None:
    out = tmp_path / "out.mp4"
    with VideoWriter(out, fps=25, size=(64, 48)) as writer:
        assert writer.backend == "ffmpeg"
        for img in _frames(12):
            writer.write(img)
    assert _count(out) == 12


def test_writer_opencv_fallback(tmp_path: Path) -> None:
    out = tmp_path / "out.mp4"
    with VideoWriter(out, fps=25, size=(64, 48), use_ffmpeg=False) as writer:
        assert writer.backend == "opencv"
        for img in _frames(8):
            writer.write(img)
    assert _count(out) == 8


def _record_with_track():
    from shuttlesense.schema import ClipRecord, Frame, Shuttle

    frames = [Frame(frame=i, shuttle=Shuttle()) for i in range(10)]
    frames[3].shuttle = Shuttle(x=20, y=20, visible=1)
    frames[5].shuttle = Shuttle(x=100, y=60, visible=1)
    return ClipRecord(clip_id="c", fps=25, width=160, height=90, num_frames=10, frames=frames)


def test_trail_draws_only_visible_points() -> None:
    from shuttlesense.render.overlays import RenderState, draw_trail

    record = _record_with_track()
    img = np.zeros((90, 160, 3), dtype=np.uint8)
    draw_trail(img, record, 6, RenderState(scale=1.0))
    assert img[20, 20].any() and img[60, 100].any()
    assert img[45, 60].sum() == 0  # nothing between the points
    assert img.any(axis=2).sum() < 400  # two small dots only


def test_layers_respect_overlay_selection() -> None:
    from shuttlesense.render.overlays import RenderState, draw_frame
    from shuttlesense.schema import Player

    record = _record_with_track()
    record.frames[5].players.near = Player(bbox=(50, 10, 40, 70), score=0.9)
    state = RenderState()
    only_boxes = draw_frame(np.zeros((90, 160, 3), np.uint8), record, 5, ["boxes"], state)
    assert not only_boxes[60, 100].any() and only_boxes[40, 50].any()
    only_trail = draw_frame(np.zeros((90, 160, 3), np.uint8), record, 5, ["trail"], state)
    assert only_trail[60, 100].any() and not only_trail[40, 50].any()
    nothing = draw_frame(np.zeros((90, 160, 3), np.uint8), record, 5, ["minimap?"], state)
    assert not nothing.any()


def test_render_stage_writes_annotated_mp4(tiny_video: Path, tmp_path: Path) -> None:
    from shuttlesense.fake import fake_pipeline

    record = fake_pipeline(tiny_video, tmp_path, clip_id="c", overlays=["trail", "pose", "boxes"])
    assert record.num_frames == 10
    assert _count(tmp_path / "annotated.mp4") == 10


def test_hit_marker_visible_only_within_duration() -> None:
    from shuttlesense.render.overlays import RenderState, draw_hits, draw_strokes
    from shuttlesense.schema import Hit, Player

    record = _record_with_track()
    kps = [(0.0, 0.0, 0.0)] * 17
    kps[9] = (80.0, 40.0, 0.9)
    for f in record.frames:
        f.players.near = Player(bbox=(60, 30, 40, 50), keypoints=kps, score=0.9)
    record.hits = [Hit(id=0, frame=2, time_s=0.08, player="near", stroke="smash", confidence=0.81)]
    state = RenderState(config={"stages": {"hits": {"marker_duration_s": 0.2}}})  # 5 frames
    blank = np.zeros((90, 160, 3), np.uint8)
    for frame, expected in ((1, False), (2, True), (7, True), (8, False)):
        img = blank.copy()
        draw_hits(img, record, frame, state)
        assert img.any() == expected, frame
    img = blank.copy()
    draw_strokes(img, record, 9, state)  # label stays until the next hit
    assert img.any()


def test_court_lines_hit_corners() -> None:
    from shuttlesense.court import compute_homography
    from shuttlesense.render.overlays import RenderState, court_segments_px
    from shuttlesense.schema import ClipRecord, Court

    corners = [[20.0, 80.0], [140.0, 80.0], [120.0, 20.0], [40.0, 20.0]]
    h = compute_homography(corners)
    record = ClipRecord(clip_id="c", fps=25, width=160, height=90, num_frames=1,
                        court=Court(corners_px=corners, homography=h.tolist()))  # fmt: skip
    outline = court_segments_px(record, RenderState())[:4]
    assert [list(a) for a, _b in outline] == corners


def test_status_text() -> None:
    from shuttlesense.fake import load_golden
    from shuttlesense.render.overlays import status_text

    text = status_text(load_golden(), 50)
    assert text.startswith("In play") and "km/h (est.)" in text and text.endswith("3 strokes")


def test_minimap_layer_draws_in_corner() -> None:
    from shuttlesense.analytics.stage import run as analytics_run
    from shuttlesense.fake import load_golden
    from shuttlesense.render.overlays import RenderState, draw_minimap, minimap_rect
    from shuttlesense.stage import StageContext

    record = analytics_run(load_golden(), StageContext(video_path=None, out_dir=None))
    img = np.zeros((720, 1280, 3), np.uint8)
    draw_minimap(img, record, 10, RenderState())
    x, y, w, h = minimap_rect(img.shape, record.court.court_size_m, "top-right")
    assert h == 144 and x + w < 1280 and y < 50
    inside = img[y : y + h, x : x + w]
    assert inside.any()
    outside = img.copy()
    outside[y : y + h, x : x + w] = 0
    assert not outside.any()
