from __future__ import annotations

import numpy as np
import pytest

from shuttlesense.analytics.positions import player_point, project_positions
from shuttlesense.analytics.speed import hit_speed, speeds_kmh
from shuttlesense.analytics.stage import count_strokes, strokes_so_far
from shuttlesense.analytics.stage import run as analytics_run
from shuttlesense.fake import load_golden
from shuttlesense.schema import Hit, Player, Rally
from shuttlesense.stage import StageContext


def test_player_position_uses_ankles() -> None:
    kps = [(0.0, 0.0, 0.9)] * 17
    kps[15] = (100.0, 500.0, 0.9)
    kps[16] = (140.0, 520.0, 0.8)
    p = Player(bbox=(80, 300, 80, 240), keypoints=kps)
    assert player_point(p) == (120.0, 510.0)


def test_falls_back_to_bbox_bottom() -> None:
    kps = [(0.0, 0.0, 0.9)] * 17
    kps[16] = (140.0, 520.0, 0.1)  # one ankle not confident
    assert player_point(Player(bbox=(80, 300, 80, 240), keypoints=kps)) == (120.0, 540.0)
    assert player_point(Player(bbox=(80, 300, 80, 240))) == (120.0, 540.0)


def test_positions_null_without_court() -> None:
    record = load_golden()
    record.court = None
    out = analytics_run(record, StageContext(video_path=None, out_dir=None))
    assert all(f.court_positions is None for f in out.frames)
    assert all(f.shuttle_speed_kmh is None for f in out.frames)


def test_positions_with_court_are_on_court() -> None:
    record = load_golden()
    pos = project_positions(record)
    near = pos["near"][~np.isnan(pos["near"]).any(axis=1)]
    assert len(near) == 60 and (near[:, 1] < 6.7).all()  # near player on the near half
    far = pos["far"][~np.isnan(pos["far"]).any(axis=1)]
    assert (far[:, 1] > 6.7).all()


def test_speed_constant_motion_and_none_across_gaps() -> None:
    xy = np.array([[0.0, i * 0.5] for i in range(10)])  # 0.5 m per frame at 30 fps = 54 km/h
    xy[5:9] = np.nan  # 4-frame gap
    kmh = speeds_kmh(xy, fps=30, smooth=1)
    assert kmh[1] == pytest.approx(54.0)
    assert np.isnan(kmh[5:9]).all()
    assert np.isnan(kmh[9])  # no previous valid point within 2 frames
    xy2 = np.array([[0.0, i * 0.5] for i in range(6)])
    xy2[2] = np.nan  # 1-frame gap: speed spans it
    assert speeds_kmh(xy2, fps=30, smooth=1)[3] == pytest.approx(54.0)


def test_implausible_speed_dropped() -> None:
    xy = np.array([[0.0, 0.0], [0.0, 10.0], [0.0, 20.0]])  # 300 m/s
    assert np.isnan(speeds_kmh(xy, fps=30, smooth=1)).all()


def test_hit_speed_is_post_hit_peak() -> None:
    kmh = np.array([10, 20, 30, 200, 150, 100, 90, 80, 250], float)
    assert hit_speed(kmh, 2, after=5) == 200.0  # frame 8 is outside the window
    assert hit_speed(np.full(5, np.nan), 0) is None


def test_stroke_count_per_rally() -> None:
    record = load_golden()
    record.hits = [Hit(id=i, frame=f, time_s=0, player="near") for i, f in enumerate([5, 20, 40])]
    record.rallies = [Rally(index=0, start_frame=0, end_frame=25),
                      Rally(index=1, start_frame=30, end_frame=59)]  # fmt: skip
    count_strokes(record)
    assert [r.stroke_count for r in record.rallies] == [2, 1]
    assert strokes_so_far(record, 22) == 2 and strokes_so_far(record, 45) == 1
    record.rallies = []
    assert strokes_so_far(record, 45) == 3


def test_stage_fills_speeds_and_summary() -> None:
    record = load_golden()
    out = analytics_run(record, StageContext(video_path=None, out_dir=None))
    assert any(f.shuttle_speed_kmh for f in out.frames)
    assert out.summary.total_hits == 3 and out.rallies[0].stroke_count == 3
