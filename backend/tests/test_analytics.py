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


def test_stage_reads_the_pose_keypoint_threshold() -> None:
    record = load_golden()
    for f in record.frames:
        if f.players.near is not None and len(f.players.near.keypoints) == 17:
            kps = list(f.players.near.keypoints)
            kps[15], kps[16] = (kps[15][0], kps[15][1], 0.4), (kps[16][0], kps[16][1], 0.4)
            f.players.near.keypoints = kps
    default = project_positions(record)["near"]
    strict = project_positions(record, min_keypoint_score=0.5)["near"]
    assert not np.allclose(default, strict, equal_nan=True)  # 0.4 ankles: used, then not

    def near_positions(config: dict) -> list:
        out = analytics_run(record.model_copy(deep=True), StageContext(None, None, config=config))
        return [f.court_positions.near for f in out.frames if f.court_positions]

    strict_cfg = {"stages": {"pose": {"min_keypoint_score": 0.5}}}
    assert near_positions({}) != near_positions(strict_cfg)


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


def test_glitch_frame_does_not_leak_into_neighbours() -> None:
    # 1 m per frame at 30 fps = 108 km/h, with one 10 m jump (1080 km/h) in the middle.
    xy = np.array([[i, 0.0] for i in range(10)])
    xy[5:] += [10.0, 0.0]
    kmh = speeds_kmh(xy, fps=30, smooth=3)
    assert np.isnan(kmh[5])
    assert np.nanmax(kmh) == pytest.approx(108.0)


# Doubles (T9.8) ------------------------------------------------------------------------------


def _doubles_golden():
    from pathlib import Path

    from shuttlesense.schema import load_record

    path = Path(__file__).parent / "fixtures" / "golden_record_doubles.json"
    return load_record(path.read_text(encoding="utf-8"))


def test_doubles_summary_counts_each_partner() -> None:
    from shuttlesense.analytics.export import build_summary

    summary = build_summary(_doubles_golden())
    assert summary.per_player["near"].hits == 2 and summary.per_player["far"].hits == 1
    assert summary.per_player["near_1"].hits == 1 and summary.per_player["near_2"].hits == 1
    assert summary.per_player["far_1"].hits == 1 and summary.per_player["far_2"].hits == 0


def test_doubles_positions_cover_both_partners() -> None:
    from shuttlesense.analytics.positions import apply_positions, project_positions

    record = _doubles_golden()
    positions = project_positions(record)
    assert set(positions) == {"near", "far", "near_2", "far_2", "shuttle"}
    apply_positions(record, positions)
    assert record.frames[10].court_positions.near_2 is not None
    assert record.frames[10].court_positions.far_2 is not None


def test_doubles_notes_name_the_partner_and_the_formation() -> None:
    from shuttlesense.feedback import build_coaching

    coaching = build_coaching(_doubles_golden(), {"patterns": {"min_count": 1}})
    ids = {n.id for n in coaching.session_notes}
    assert "elbow_extension:near_2" in ids and "elbow_extension:far_1" in ids
    formation = [n for n in coaching.session_notes if n.rule == "formation"]
    assert {n.player for n in formation} == {"near", "far"}
    assert all(n.severity == 0 and n.id not in coaching.top_fixes for n in formation)
    assert formation[0].text.startswith("Near pair: ")


def test_singles_summary_has_no_partner_keys() -> None:
    from shuttlesense.analytics.export import build_summary
    from shuttlesense.fake import load_golden

    assert set(build_summary(load_golden()).per_player) == {"near", "far"}


def test_hits_csv_names_the_doubles_partner(tmp_path) -> None:
    import csv

    from shuttlesense.analytics.export import write_exports

    record = _doubles_golden()
    write_exports(record, tmp_path)
    with open(tmp_path / "hits.csv", encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    assert [r["hitter"] for r in rows] == [h.hitter or "" for h in record.hits]
    assert any(r["hitter"] for r in rows)
