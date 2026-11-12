"""Command-line tools that had no tests: live replay, the live benchmark, Colab and features."""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from test_eval_scripts import load_script


def test_live_replay_in_process_reports_latency_and_events(tmp_path: Path, capsys) -> None:
    from shuttlesense import live_replay

    out = tmp_path / "replay.json"
    assert live_replay.main(["--in-process", "--fake", "--frames", "60", "--json", str(out)]) == 0
    result = json.loads(out.read_text(encoding="utf-8"))
    assert result["frames"] == 60 and result["events"]["frame"] == 60
    assert set(result["round_trip_ms"]) == {"p50", "p95", "p99"}
    assert result["stages"]["synthetic"] is True and result["job_id"]
    assert json.loads(capsys.readouterr().out) == result


def test_live_replay_reports_event_lag_in_frames(tmp_path: Path) -> None:
    from shuttlesense import live_replay

    out = tmp_path / "replay.json"
    live_replay.main(["--in-process", "--fake", "--frames", "240", "--json", str(out)])
    lag = json.loads(out.read_text(encoding="utf-8"))["event_lag"]
    # Hits wait for the stroke window's look-ahead; rallies for the rest rule on top.
    assert lag["hit"]["count"] >= 1 and lag["hit"]["frames"]["p50"] >= 6
    assert lag["rally"]["frames"]["p50"] > lag["hit"]["frames"]["p50"]


@pytest.mark.parametrize("fps,expected", [
    (60.0, [0, 2, 4, 6, 8, 10]),
    (36.0, [0, 1, 2, 4, 5, 6, 7, 8, 10, 11]),
])  # fmt: skip
def test_live_replay_sends_only_the_frames_the_server_keeps(fps, expected) -> None:
    from shuttlesense import live_replay

    class Server:
        """Answers like WS /live with a 30 fps cap: one frame event per frame received."""

        def __init__(self) -> None:
            self.frames: list[int] = []
            self.pending: list[dict] = []

        def send_json(self, data: dict) -> None:
            if data["type"] == "start":
                self.pending.append({"type": "started", "fps": 30.0, "stages": {}})
            elif data["type"] == "stop":
                self.pending.append({"type": "saved", "job_id": None})

        def send_bytes(self, data: bytes) -> None:
            index = int.from_bytes(data[:4], "little")
            self.frames.append(index)
            self.pending.append({"type": "frame", "client_frame": index, "latency_ms": 1.0})

        def receive_json(self) -> dict:
            return self.pending.pop(0)

    import numpy as np

    server = Server()
    frames = (np.zeros((8, 8, 3), np.uint8) for _ in range(12))
    result = live_replay.run(server, frames, fps=fps, width=8, height=8)
    assert server.frames == expected and result["frames"] == len(expected)


def test_bench_live_writes_a_report_that_says_what_it_measured(tmp_path: Path) -> None:
    bench_live = load_script("bench_live")
    out = tmp_path / "live_latency.md"
    bench_live.main(["--fake", "--frames", "40", "--out", str(out)])
    text = out.read_text(encoding="utf-8")
    assert text.startswith("# Live latency (T8.12)")
    assert "fake perception (in-process); frames: 40" in text
    assert "They are not the GPU latency." in text
    assert "--fake --frames 40" in text
    assert json.loads(out.with_suffix(".json").read_text(encoding="utf-8"))["frames"] == 40


def test_bench_live_flags_a_server_without_models() -> None:
    import argparse

    bench_live = load_script("bench_live")
    result = {"round_trip_ms": {"p50": 80.0}, "server_ms": {}, "frames": 10,
              "stages": {"tracking": True, "pose": False}, "throughput_fps": 9.0}  # fmt: skip
    args = argparse.Namespace(fake=False, url="ws://gpu:8000/live", video=None)
    text = bench_live.to_markdown(result, args, "python scripts/bench_live.py")
    assert "| 80.0 | – | – |" in text and "does not show the full perception cost" in text


def test_bench_report_omits_connection_secrets_and_private_paths(tmp_path, monkeypatch, capsys):
    bench = load_script("bench_live")
    result = {
        "stages": {"tracking": False, "pose": False, "synthetic": True},
        "frames": 1, "throughput_fps": 10, "round_trip_ms": {}, "server_ms": {},
    }  # fmt: skip

    def replay(args):
        assert args[args.index("--token") + 1] == "cli-secret"
        Path(args[args.index("--json") + 1]).write_text(json.dumps(result), encoding="utf-8")

    monkeypatch.setattr(bench.live_replay, "main", replay)
    monkeypatch.setattr(bench, "RESULTS_DIR", tmp_path)
    bench.main([
        "--url=wss://alice:url-secret@private.example/live?token=query-secret",
        "--token=cli-secret", "--video", str(tmp_path / "private clip.mp4"),
    ])  # fmt: skip
    report = (tmp_path / "live_latency_fake.md").read_text(encoding="utf-8")
    assert "fake perception (remote)" in report
    assert "--url <live-url>" in report and "--video <input-video>" in report
    stdout = capsys.readouterr().out
    for secret in (
        "alice",
        "url-secret",
        "private.example",
        "query-secret",
        "cli-secret",
        "private clip.mp4",
        str(tmp_path),
    ):
        assert secret not in report and secret not in stdout


@pytest.mark.parametrize("stages,message", [
    ({"synthetic": True, "tracking": True, "pose": True}, "needs real tracking and pose"),
    ({"tracking": True, "pose": False}, "needs real tracking and pose"),
    ({"tracking": True, "pose": True}, "no analyzed frame samples"),
])  # fmt: skip
def test_strict_replay_rejects_non_model_or_empty_runs(stages, message):
    from shuttlesense import live_replay

    class Server:
        messages = []
        replies = iter(
            [
                {"type": "started", "stages": stages, "fps": 30},
                {"type": "saved", "job_id": None},
            ]
        )

        def send_json(self, msg):
            self.messages.append(msg["type"])

        def receive_json(self):
            return next(self.replies)

    server = Server()
    with pytest.raises(ValueError, match=message):
        live_replay.run(server, iter([]), fps=30, width=8, height=8, require_models=True)
    assert server.messages == ["start", "stop"]


def test_colab_tunnel_url_is_found_in_the_cloudflared_log() -> None:
    serve_colab = load_script("serve_colab")
    line = "2026-11-01T10:00:00Z INF |  https://quiet-river-1234.trycloudflare.com  |"
    assert serve_colab.tunnel_url(line) == "https://quiet-river-1234.trycloudflare.com"
    assert serve_colab.tunnel_url("INF Starting tunnel tunnelID=abc") is None
    assert serve_colab.tunnel_url("see https://example.com for help") is None


def test_hitter_side_picks_the_wrist_next_to_the_shuttle() -> None:
    from shuttlesense.schema import Shuttle
    from shuttlesense.stream.synthetic import synthetic_record

    extract_features = load_script("extract_features")
    record, truth = synthetic_record()
    for frame, side, _ in truth["hits"]:
        assert extract_features.hitter_side(record, frame) == side
    record.frames[0].shuttle = Shuttle()
    assert extract_features.hitter_side(record, 0) == "near"  # no shuttle: the default
    assert extract_features.hitter_side(record, 10**6) in ("near", "far")  # past the end
