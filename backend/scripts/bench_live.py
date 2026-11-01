"""Live latency benchmark (T8.12): frame sent -> overlay event back, through WS /live.

Usage: python scripts/bench_live.py --fake [--frames 300]            # no GPU, no models
       python scripts/bench_live.py --url ws://127.0.0.1:8000/live --video ../samples/rally01.mp4
                [--corners x1,y1,...] [--realtime] [--out ../docs/results/live_latency.md]

Runs shuttlesense.live_replay and writes a report with the numbers and the setup they come
from. --fake starts the API in-process with fake perception, so it measures the socket,
JPEG decode, the windowed analysis and the event path only, not TrackNetV3 or pose; the
report says so. GPU numbers need a server started with the weights installed (see the
`stages` line in the report: both must be true).
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

from shuttlesense.config import BACKEND_DIR, load_config

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"


def _gpu() -> str:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
            capture_output=True, text=True, timeout=10, check=True,
        )  # fmt: skip
        return out.stdout.strip() or "none"
    except (OSError, subprocess.SubprocessError):
        return "none found"


def _commit() -> str:
    try:
        out = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True,
                             text=True, timeout=10, check=True)  # fmt: skip
        return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return "unknown"


def to_markdown(result: dict, args: argparse.Namespace, command: str) -> str:
    budget = load_config().get("live", {}).get("budget_ms", 300)
    rt, srv = result["round_trip_ms"], result["server_ms"]
    mode = "fake perception (in-process)" if args.fake else f"server {args.url}"
    lines = [
        "# Live latency (T8.12)",
        "",
        f"- Run: {datetime.now(UTC):%Y-%m-%d %H:%M} UTC, commit `{_commit()}`",
        f"- Command: `{command}`",
        f"- Mode: {mode}; frames: {result['frames']}; source: "
        f"{args.video.name if args.video else 'synthetic 1280x720 frames'}",
        f"- Machine: {platform.platform()}, Python {platform.python_version()}, GPU: {_gpu()}",
        f"- Models on the server: {json.dumps(result['stages'])}",
        "",
        "| Measure | p50 | p95 | p99 |",
        "| --- | --- | --- | --- |",
        f"| Frame sent -> frame event back (ms) | {rt.get('p50', '–')} | {rt.get('p95', '–')} "
        f"| {rt.get('p99', '–')} |",
        f"| Server: arrival -> event (ms) | {srv.get('p50', '–')} | {srv.get('p95', '–')} "
        f"| {srv.get('p99', '–')} |",
        "",
        f"Throughput (frames processed one at a time): {result['throughput_fps']} fps. "
        f"Budget: p95 <= {budget} ms.",
        "",
    ]
    if args.fake:
        lines.append(
            "Fake perception replays synthetic rallies instead of running TrackNetV3 and pose, "
            "so these numbers are the overhead of everything around the models. They are not "
            "the GPU latency."
        )
    elif not (result["stages"].get("tracking") and result["stages"].get("pose")):
        lines.append(
            "Some models were not installed on the server, so this run does not show the "
            "full perception cost."
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--fake", action="store_true", help="in-process API, fake perception")
    parser.add_argument("--url", default="ws://127.0.0.1:8000/live")
    parser.add_argument("--token")
    parser.add_argument("--video", type=Path)
    parser.add_argument("--frames", type=int, default=300)
    parser.add_argument("--corners")
    parser.add_argument("--realtime", action="store_true")
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "live_latency.md")
    args = parser.parse_args(argv)

    from shuttlesense import live_replay

    replay = ["--frames", str(args.frames), "--json", str(args.out.with_suffix(".json"))]
    if args.fake:
        replay += ["--in-process", "--fake"]
    else:
        replay += ["--url", args.url] + (["--token", args.token] if args.token else [])
    if args.video:
        replay += ["--video", str(args.video)]
    if args.corners:
        replay += ["--corners", args.corners]
    if args.realtime:
        replay.append("--realtime")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    live_replay.main(replay)
    result = json.loads(args.out.with_suffix(".json").read_text(encoding="utf-8"))
    command = "python scripts/bench_live.py " + " ".join(sys.argv[1:] if argv is None else argv)
    markdown = to_markdown(result, args, command)
    args.out.write_text(markdown, encoding="utf-8")
    print(markdown)


if __name__ == "__main__":
    main()
