from __future__ import annotations

import json
from pathlib import Path

import pytest
from snapshots import assert_matches_snapshot

from shuttlesense.schema import SCHEMA_VERSION, STROKE_CLASSES, ClipRecord, load_record, migrate

EXAMPLE = {
    "schema_version": "1.4",
    "clip_id": "match03_rally12",
    "mode": "live",
    "source_name": "rally12.mp4",
    "fps": 30.0,
    "width": 1280,
    "height": 720,
    "num_frames": 900,
    "court": {
        "corners_px": [[212.0, 650.0], [1068.0, 650.0], [880.0, 210.0], [400.0, 210.0]],
        "homography": [[0.01, 0.0, -2.1], [0.0, 0.03, -6.4], [0.0, 0.0, 1.0]],
        "court_size_m": [5.18, 13.40],
    },
    "frames": [
        {
            "frame": 0,
            "shuttle": {"x": 512.0, "y": 288.0, "visible": 1},
            "players": {
                "near": {
                    "bbox": [480.0, 400.0, 120.0, 300.0],
                    "score": 0.94,
                    "keypoints": [[540.0, 420.0, 0.91]] * 17,
                },
                "far": None,
            },
            "court_positions": {"near": [2.6, 1.9], "far": [2.4, 11.8], "shuttle": None},
            "shuttle_speed_kmh": None,
            "rally_state": "in_play",
        }
    ],
    "hits": [
        {
            "id": 0,
            "frame": 42,
            "time_s": 1.4,
            "player": "near",
            "stroke": "smash",
            "confidence": 0.81,
            "class_probs": {"smash": 0.81, "clear": 0.19},
            "speed_kmh": 182.0,
            "feedback": [
                {
                    "rule": "elbow_extension",
                    "passed": False,
                    "tip": "Extend your arm.",
                    "value": 131.0,
                }
            ],
            "rally_index": 0,
        }
    ],
    "rallies": [
        {
            "index": 0,
            "start_frame": 12,
            "end_frame": 410,
            "stroke_count": 7,
            "landing": {"x_m": 4.9, "y_m": 12.1, "in_court": True, "confidence": 0.72},
            "winner": "near",
            "score_after": {"near": 11, "far": 9},
        }
    ],
    "score": {"near": 11, "far": 9, "corrections": []},
    "summary": None,
    "line_calls": [
        {
            "id": 0,
            "rally_index": 0,
            "frame": 400,
            "time_s": 13.333,
            "call": "in",
            "landing_xy": [4.9, 12.1],
            "margin_cm": 28.0,
            "confidence": 0.72,
            "uncertain": False,
            "court": "singles",
            "override": None,
        }
    ],
    "rally_events": [
        {"frame": 12, "time_s": 0.4, "type": "rally_start", "rally_index": 0, "data": {}},
        {
            "frame": 400,
            "time_s": 13.333,
            "type": "landing",
            "rally_index": 0,
            "data": {"call": "in"},
        },
    ],
    "coaching": {
        "session_notes": [
            {
                "id": "elbow_extension:near",
                "player": "near",
                "rule": "elbow_extension",
                "stroke": "smash",
                "text": "Bent elbow at contact on 1 of 1 smashes",
                "count": 1,
                "total": 1,
                "severity": 1.0,
                "moments": [{"frame": 42, "time_s": 1.4, "hit_id": 0}],
            }
        ],
        "top_fixes": ["elbow_extension:near"],
    },
    "chat": {
        "messages": [
            {"role": "user", "text": "Why short?", "at": "2026-10-31T10:00:00Z", "citations": []},
        ]
    },
}


def test_example_from_docs_round_trips() -> None:
    record = ClipRecord.model_validate(EXAMPLE)
    again = ClipRecord.model_validate_json(record.model_dump_json())
    assert again == record
    assert again.hits[0].stroke == "smash"
    assert again.frames[0].players.far is None
    assert again.mode == "live" and again.line_calls[0].effective_call == "in"
    assert again.coaching.top_fixes == ["elbow_extension:near"]


def test_migrate_1_0_record() -> None:
    old = json.loads(json.dumps(EXAMPLE))
    old["schema_version"] = "1.0"
    for key in ("mode", "line_calls", "rally_events", "coaching", "chat"):
        del old[key]
    for item in old["hits"][0]["feedback"]:
        del item["value"]
    record = load_record(json.dumps(old))
    assert record.schema_version == SCHEMA_VERSION
    assert record.mode == "upload"
    assert record.chat is None and record.coaching is None
    assert record.hits[0].feedback[0].value is None


def test_migrate_refuses_other_major_version() -> None:
    with pytest.raises(ValueError, match="cannot migrate"):
        migrate({"schema_version": "2.0"})


def test_minimal_record_defaults() -> None:
    record = ClipRecord(clip_id="c", fps=30, width=1280, height=720, num_frames=0)
    assert record.schema_version == SCHEMA_VERSION
    assert record.court is None
    assert record.hits == [] and record.rallies == []
    assert record.mode == "upload" and record.line_calls == [] and record.chat is None


def test_stroke_classes_are_the_six_documented() -> None:
    assert STROKE_CLASSES == ("smash", "clear", "drop", "net_shot", "lift", "serve")


def test_json_schema_snapshot() -> None:
    fixture = Path(__file__).parent / "fixtures" / "clip_record.schema.json"
    assert_matches_snapshot(ClipRecord.model_json_schema(), fixture)


def test_golden_record_valid() -> None:
    from shuttlesense.fake import load_golden

    record = load_golden()
    assert record.num_frames == len(record.frames) == 60
    assert [h.stroke for h in record.hits] == ["serve", "clear", "smash"]
    assert all(
        len(p.keypoints) == 17 for f in record.frames for p in (f.players.near, f.players.far)
    )
    assert record.court is not None and record.summary.total_hits == 3


def test_migrate_1_1_record_adds_nothing() -> None:
    old = json.loads(json.dumps(EXAMPLE))
    old["schema_version"] = "1.1"
    old["line_calls"] = []  # 1.1 records keep the calls they have; only 1.0 derives them
    record = load_record(json.dumps(old))
    assert record.schema_version == SCHEMA_VERSION == "1.6"
    assert record.line_calls == []


def test_singles_records_serialize_without_doubles_fields() -> None:
    """v1.2 fields are left out while empty, so singles output is the same as in v1.1."""
    from shuttlesense.fake import load_golden

    text = load_golden().model_dump_json()
    for key in ("near_2", "far_2", "hitter", "server_id", "receiver_id", "first_server_id",
                "first_receiver_id", "review", "game_service"):  # fmt: skip
        assert f'"{key}"' not in text


def test_player_slots() -> None:
    from shuttlesense.schema import Hit, Player, Players, side_of, slot_attr, slot_id

    assert [slot_attr(p) for p in ("near_1", "near_2", "far_1", "far_2", "near")] == [
        "near", "near_2", "far", "far_2", "near",
    ]  # fmt: skip
    assert side_of("far_2") == "far" and slot_id("near") == "near_1" and slot_id("far_2") == "far_2"
    p = Player(bbox=(0, 0, 1, 1))
    players = Players(near=p, far_2=p)
    assert players.slots() == {"near_1": p, "near_2": None, "far_1": None, "far_2": p}
    assert players.model_dump(mode="json")["far_2"]["bbox"] == [0, 0, 1, 1]
    hit = Hit(id=0, frame=0, time_s=0, player="far", hitter="far_2", hitter_confidence=0.8)
    assert (
        hit.player_attr == "far_2"
        and Hit(id=0, frame=0, time_s=0, player="far").player_attr == "far"
    )
    assert Hit.model_validate_json(hit.model_dump_json()) == hit


def test_doubles_golden_record_valid() -> None:
    path = Path(__file__).parent / "fixtures" / "golden_record_doubles.json"
    record = load_record(path.read_text(encoding="utf-8"))
    assert all(len(f.players.slots()) == 4 and all(f.players.slots().values())
               for f in record.frames)  # fmt: skip
    assert [h.hitter for h in record.hits] == ["near_1", "far_1", "near_2"]
    assert record.score.server_id == "near_1" and record.score.receiver_id == "far_2"
    assert record.rallies[0].server_id == "near_1" and record.line_calls[0].court == "doubles"


def test_stroke_model_is_optional_and_checked() -> None:
    """Clip record 1.4: 1.3 records load without it, and only known models are accepted."""
    import pydantic

    old = {"schema_version": "1.3", "clip_id": "c", "fps": 30, "width": 4, "height": 4,
           "num_frames": 0}  # fmt: skip
    record = ClipRecord.model_validate(migrate(dict(old)))
    assert record.schema_version == "1.6" and record.stroke_model is None
    assert ClipRecord.model_validate({**old, "stroke_model": "rf"}).stroke_model == "rf"
    with pytest.raises(pydantic.ValidationError):
        ClipRecord.model_validate({**old, "stroke_model": "svm"})
