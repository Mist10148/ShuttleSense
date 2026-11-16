from scripts.bench_watch_complete import p95
from scripts.summarize_watch_flutter import summarize


def test_flutter_summary_uses_first_frame_after_45_seconds():
    rows = [
        {"event": "received", "frame": 249, "elapsed_ms": 44900, "video_fps": 25,
         "round_trip_ms": 100},
        {"event": "received", "frame": 250, "elapsed_ms": 45100, "video_fps": 25,
         "round_trip_ms": 200},
        {"event": "next", "since_response_ms": 3},
        {"event": "clock_stopped", "elapsed_ms": 50000, "status": "Session saved"},
    ]
    result = summarize(rows)
    assert result["checkpoint_45s"] == {"elapsed_s": 45.1, "video_s": 10.04}
    assert result["round_trip_ms"]["median"] == 150
    assert result["round_trip_ms"]["p95"] == 200
    assert result["stop_status"] == ["Session saved"]


def test_p95_handles_empty_and_small_samples():
    assert p95([]) is None
    assert p95([1, 2, 3]) == 3
