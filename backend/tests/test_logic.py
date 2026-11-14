"""Pure-logic helpers that need no GPU or models."""

from __future__ import annotations

import codecs
import csv
from pathlib import Path

import numpy as np
import pytest

from shuttlesense.analytics import build_summary, speeds_kmh, write_exports
from shuttlesense.feedback import joint_angle
from shuttlesense.hits import direction_changes
from shuttlesense.pose import assign_sides
from shuttlesense.referee import game_winner
from shuttlesense.schema import ClipRecord, Hit, Player
from shuttlesense.strokes import SHUTTLESET_TO_CLASS, SHUTTLESET_ZH_TO_EN, map_label
from shuttlesense.tracking import interpolate_gaps


def test_interpolate_fills_short_gap_only() -> None:
    xy = np.array([[0, 0], [0, 0], [0, 0], [3, 3], [0, 0], [0, 0], [0, 0], [0, 0], [8, 8]], float)
    vis = np.array([1, 0, 0, 1, 0, 0, 0, 0, 1])
    out_xy, out_vis = interpolate_gaps(xy, vis, max_gap=2)
    np.testing.assert_allclose(out_xy[1:3], [[1, 1], [2, 2]])
    assert out_vis.tolist() == [1, 1, 1, 1, 0, 0, 0, 0, 1]


def test_direction_change_detected_at_bounce() -> None:
    xy = np.array([[0, 0], [1, 0], [2, 0], [3, 0], [2, 0], [1, 0]], float)
    assert direction_changes(xy, min_angle_deg=60) == [3]


def test_assign_sides_by_feet_position() -> None:
    far = Player(bbox=(100, 50, 40, 100))
    near = Player(bbox=(100, 300, 60, 200))
    assert assign_sides([far, near]) == (near, far)
    assert assign_sides([]) == (None, None)


def test_joint_angle_right_angle() -> None:
    angle = joint_angle(np.array([0.0, 1.0]), np.array([0.0, 0.0]), np.array([1.0, 0.0]))
    assert angle == pytest.approx(90.0)


def test_speed_constant_motion() -> None:
    track = np.array([[0.0, i * 0.5] for i in range(10)])  # 0.5 m per frame at 30 fps
    kmh = speeds_kmh(track, fps=30, smooth=1)
    np.testing.assert_allclose(kmh, 0.5 * 30 * 3.6)


def test_label_mapping_covers_18_types_and_unknown() -> None:
    assert len(SHUTTLESET_TO_CLASS) == 19
    assert set(SHUTTLESET_ZH_TO_EN.values()) == set(SHUTTLESET_TO_CLASS)
    assert map_label(" Wrist Smash ") == "smash"
    assert map_label("drive") is None
    assert map_label("殺球") == "smash"
    assert map_label(" 挑球 ") == "lift"
    assert map_label("未知球種") is None
    with pytest.raises(KeyError):
        map_label("tennis serve")


def test_every_shuttleset_type_in_data_is_mapped() -> None:
    """The ShuttleSet CSVs name types in Chinese; every one of them must map (T3.3)."""
    sample = Path(__file__).parent / "fixtures" / "shuttleset_sample.csv"
    with sample.open(newline="", encoding="utf-8") as f:
        types = {row["type"] for row in csv.DictReader(f)}
    assert len(types) == 19
    labels = {t: map_label(t) for t in types}
    assert set(labels.values()) == {"smash", "clear", "drop", "net_shot", "lift", "serve", None}


@pytest.mark.parametrize(
    ("near", "far", "winner"),
    [
        (21, 19, "near"),
        (20, 20, None),
        (21, 20, None),
        (22, 20, "near"),
        (29, 30, "far"),
        (5, 21, "far"),
    ],
)
def test_bwf_game_winner(near: int, far: int, winner: str | None) -> None:
    assert game_winner(near, far) == winner


def test_summary_and_exports(tmp_path) -> None:
    record = ClipRecord(
        clip_id="c",
        fps=30,
        width=1280,
        height=720,
        num_frames=100,
        hits=[
            Hit(id=0, frame=10, time_s=0.33, player="near", stroke="smash", speed_kmh=150.0),
            Hit(id=1, frame=40, time_s=1.33, player="far", stroke="lift", speed_kmh=60.0),
            Hit(id=2, frame=70, time_s=2.33, player="near", stroke="smash"),
        ],
    )
    record.summary = build_summary(record)
    assert record.summary.stroke_counts == {"smash": 2, "lift": 1}
    assert record.summary.per_player["near"].peak_speed_kmh == 150.0

    write_exports(record, tmp_path)
    rows = list(csv.DictReader((tmp_path / "hits.csv").open(encoding="utf-8-sig")))
    assert [r["stroke"] for r in rows] == ["smash", "lift", "smash"]
    assert (tmp_path / "record.json").exists() and (tmp_path / "summary.json").exists()


def test_csv_opens_with_bom(tmp_path) -> None:
    write_exports(ClipRecord(clip_id="c", fps=30, width=10, height=10, num_frames=0), tmp_path)
    for name in ("hits.csv", "rallies.csv"):
        assert (tmp_path / name).read_bytes().startswith(codecs.BOM_UTF8)


def test_summary_matches_record(tmp_path) -> None:
    import json

    from shuttlesense.fake import load_golden

    record = load_golden()
    write_exports(record, tmp_path)
    summary = json.loads((tmp_path / "summary.json").read_text())
    assert summary["summary"]["total_hits"] == len(record.hits)
    stats = summary["rally_stats"][0]
    assert stats["stroke_count"] == 3 and stats["peak_speed_kmh"] == 241.0
    assert stats["duration_s"] == round(55 / 30, 3)
    rows = list(csv.DictReader((tmp_path / "rallies.csv").open(encoding="utf-8-sig")))
    assert rows[0]["winner"] == "near" and rows[0]["score_near"] == "1"


def test_match_stats_and_referee_columns(tmp_path) -> None:
    import json
    from datetime import UTC, datetime

    from shuttlesense.fake import load_golden
    from shuttlesense.schema import LineCallOverride, ScoreCorrection

    record = load_golden()
    call = record.line_calls[0]
    call.override = LineCallOverride(call="out" if call.call == "in" else "in",
                                     at=datetime.now(UTC))  # fmt: skip
    record.score.corrections = [
        ScoreCorrection(rally_index=record.rallies[0].index, winner_before="near",
                        winner_after=None, at=datetime.now(UTC), reason="let"),
        ScoreCorrection(rally_index=1, winner_before=None, winner_after="far",
                        at=datetime.now(UTC), kind="award", reason="fault"),
    ]  # fmt: skip
    write_exports(record, tmp_path)
    match = json.loads((tmp_path / "summary.json").read_text())["match"]
    assert match["best_of"] == record.score.best_of
    assert match["decisions"] == {"corrections": 1, "awards": 1, "line_call_overrides": 1,
                                  "reasons": {"let": 1, "fault": 1}}  # fmt: skip
    serve = match["points_won_on_serve"]
    assert sum(v["served"] for v in serve.values()) <= len(record.rallies)
    assert match["longest_rally"]["strokes"] == max(r.stroke_count for r in record.rallies)
    rows = list(csv.DictReader((tmp_path / "rallies.csv").open(encoding="utf-8-sig")))
    assert rows[0]["game"] == "1" and rows[0]["call"] == call.effective_call
    assert rows[0]["decision"] == f"call overridden {call.override.call}; cleared (let)"
