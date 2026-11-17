from scripts.bench_watch_complete import p95
from scripts.summarize_watch_flutter import summarize


def test_flutter_summary_uses_first_frame_after_45_seconds():
    rows = [
        {
            "event": "received",
            "frame": 249,
            "elapsed_ms": 44900,
            "video_fps": 25,
            "round_trip_ms": 100,
        },
        {
            "event": "received",
            "frame": 250,
            "elapsed_ms": 45100,
            "video_fps": 25,
            "round_trip_ms": 200,
        },
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


def test_flutter_summary_separates_decode_frame_and_transport_timings():
    result = summarize(
        [
            {
                "event": "received",
                "frame": 1,
                "previous_transport": {"frame": 0, "serialize_ms": 2.5, "send_await_ms": 3.0},
            },
            {"event": "image_ready", "frame": 0, "since_response_ms": 8},
            {"event": "image_stream_decode", "frame": 0, "decode_ms": 6.5},
            {"event": "frame_timing", "build_ms": 1.0, "raster_ms": 4.0},
        ]
    )
    assert result["image_ready_since_response_ms"]["median"] == 8
    assert result["image_stream_decode_ms"]["median"] == 6.5
    assert result["frame_build_ms"]["median"] == 1
    assert result["frame_raster_ms"]["median"] == 4
    assert result["server_serialize_ms"]["median"] == 2.5
    assert result["server_send_await_ms"]["median"] == 3


def test_delivery_interval_requires_same_host_opt_in():
    rows = [
        {
            "event": "received",
            "frame": 1,
            "server_serialize_epoch_us": 1000000,
            "client_receive_epoch_us": 1012500,
        }
    ]
    key = "serialize_start_to_client_receive_ms_same_host"
    assert summarize(rows)[key] is None
    assert summarize(rows, same_host=True)[key]["median"] == 12.5


def test_delivery_analysis_accounts_for_frame_pacing():
    rows = [
        {
            "event": "received",
            "round_trip_ms": 100,
            "video_fps": 25,
            "server_ms": {"read": 10, "jpeg": 2, "processing": 80},
        },
        {
            "event": "received",
            "round_trip_ms": 30,
            "video_fps": 25,
            "server_ms": {"read": 5, "jpeg": 2, "processing": 20},
        },
    ]
    result = summarize(rows)
    assert result["server_read_ms"]["median"] == 7.5
    assert result["pacing_below_frame_interval"] == {"count": 1, "frames": 2}
    # The second read is hidden by pacing even without prefetch.
    assert result["ideal_read_overlap_cycle_reduction_pct"] == 7.14
