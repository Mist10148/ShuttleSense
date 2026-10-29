from __future__ import annotations

from shuttlesense.schema import SCHEMA_VERSION, STROKE_CLASSES, ClipRecord

EXAMPLE = {
    "schema_version": "1.0",
    "clip_id": "match03_rally12",
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
            "feedback": [{"rule": "elbow_extension", "passed": False, "tip": "Extend your arm."}],
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
}


def test_example_from_docs_round_trips() -> None:
    record = ClipRecord.model_validate(EXAMPLE)
    again = ClipRecord.model_validate_json(record.model_dump_json())
    assert again == record
    assert again.hits[0].stroke == "smash"
    assert again.frames[0].players.far is None


def test_minimal_record_defaults() -> None:
    record = ClipRecord(clip_id="c", fps=30, width=1280, height=720, num_frames=0)
    assert record.schema_version == SCHEMA_VERSION
    assert record.court is None
    assert record.hits == [] and record.rallies == []


def test_stroke_classes_are_the_six_documented() -> None:
    assert STROKE_CLASSES == ("smash", "clear", "drop", "net_shot", "lift", "serve")
