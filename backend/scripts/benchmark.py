"""Processing-time benchmark: run the pipeline N times and aggregate timings.json (T2.9).

Usage: python scripts/benchmark.py --video X [--runs 3] [--device cuda] [--disable render]
                [--corners x1,y1,...,x4,y4] [--referee] [--out ../docs/results/benchmark.md]

Each run uses a fresh output directory, so the stage cache never hides work. Stages whose
packages or weights are missing skip themselves (as in the app), so this runs on a CPU-only
laptop too; the table marks them. Court and referee only run with --corners (and --referee),
as in the app. Prints the median wall time per stage, the total and the
processed frames per second, and writes the table (.md) plus the raw numbers (.json).
"""

from __future__ import annotations

import argparse
import json
import statistics
import tempfile
from pathlib import Path
from typing import Any

from shuttlesense.config import BACKEND_DIR, detect_device, load_config

RESULTS_DIR = BACKEND_DIR.parent / "docs" / "results"


def run_once(
    video: Path,
    out_dir: Path,
    config: dict[str, Any],
    device: str,
    corners: list[list[float]] | None = None,
    referee: bool = False,
) -> tuple[dict[str, float], int, list[str]]:
    """One pipeline run into out_dir: (timings.json, frames processed, skipped stages)."""
    from shuttlesense.pipeline import run_pipeline

    started: set[str] = set()
    skipped: list[str] = []

    def on_event(name: str, status: str, _progress: float) -> None:
        # Disabled stages are reported "skipped" up front; only count stages that started.
        if status == "running":
            started.add(name)
        elif status == "skipped" and name in started and name not in skipped:
            skipped.append(name)

    record = run_pipeline(
        video, out_dir, clip_id=video.stem, config=config, device=device, on_event=on_event,
        court_corners_px=corners, referee_enabled=referee,
    )  # fmt: skip
    timings = json.loads((out_dir / "timings.json").read_text(encoding="utf-8"))
    return timings, record.num_frames, skipped


def aggregate(runs: list[dict[str, float]], num_frames: int) -> dict[str, Any]:
    """Median seconds per stage (stages in first-seen order), median total and fps."""
    stages: list[str] = []
    for t in runs:
        stages += [name for name in t if name not in stages]
    median = {
        name: round(statistics.median(t[name] for t in runs if name in t), 3) for name in stages
    }
    totals = [sum(t.values()) for t in runs]
    total = round(statistics.median(totals), 3) if totals else 0.0
    return {
        "runs": len(runs),
        "num_frames": num_frames,
        "stage_median_s": median,
        "total_median_s": total,
        "total_min_s": round(min(totals), 3) if totals else 0.0,
        "total_max_s": round(max(totals), 3) if totals else 0.0,
        "fps": round(num_frames / total, 2) if total else 0.0,
    }


def benchmark(
    video: Path,
    *,
    runs: int = 3,
    config: dict[str, Any] | None = None,
    device: str = "cpu",
    work_dir: Path | None = None,
    corners: list[list[float]] | None = None,
    referee: bool = False,
) -> dict[str, Any]:
    """Run the pipeline `runs` times (fresh out dir each) and return the aggregate."""
    from shuttlesense.io import probe

    config = config if config is not None else load_config()
    info = probe(video)
    timings, skipped, num_frames = [], set(), 0
    with tempfile.TemporaryDirectory(dir=work_dir) as tmp:
        for i in range(runs):
            out = Path(tmp) / f"run{i}"
            t, num_frames, s = run_once(video, out, config, device, corners, referee)
            timings.append(t)
            skipped.update(s)
    result = aggregate(timings, num_frames)
    result.update(
        video=video.name,
        device=device,
        source={"width": info.width, "height": info.height, "fps": info.fps,
                "duration_s": round(info.duration_s, 2)},
        skipped_stages=sorted(skipped),
        raw_timings=timings,
    )  # fmt: skip
    return result


def to_markdown(result: dict[str, Any]) -> str:
    src = result["source"]
    lines = [
        "# Processing time",
        "",
        f"Video `{result['video']}`: {src['width']}x{src['height']} at {src['fps']:.2f} fps, "
        f"{src['duration_s']} s. Device `{result['device']}`, median of {result['runs']} runs.",
        "",
        "| Stage | Median (s) | Note |",
        "| --- | ---: | --- |",
    ]
    for name, seconds in result["stage_median_s"].items():
        note = "skipped" if name in result["skipped_stages"] else ""
        lines.append(f"| {name} | {seconds:.3f} | {note} |")
    lines += [
        f"| **total** | **{result['total_median_s']:.3f}** | "
        f"min {result['total_min_s']:.3f}, max {result['total_max_s']:.3f} |",
        "",
        f"{result['num_frames']} frames processed, {result['fps']:.2f} frames/s.",
        "",
    ]
    return "\n".join(lines)


def write_report(result: dict[str, Any], out_md: Path) -> None:
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(to_markdown(result), encoding="utf-8")
    out_md.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    from shuttlesense.pipeline import STAGE_NAMES
    from shuttlesense.run import parse_corners

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    parser.add_argument("--config", type=Path, default=None, help="default configs/pipeline.yaml")
    parser.add_argument("--disable", default="", help="comma-separated stages to turn off")
    parser.add_argument("--corners", type=parse_corners, help="court corners x1,y1,...,x4,y4")
    parser.add_argument("--referee", action="store_true", help="also run the referee stage")
    parser.add_argument("--out", type=Path, default=RESULTS_DIR / "benchmark.md")
    args = parser.parse_args()
    if not args.video.exists():
        raise SystemExit(f"video not found: {args.video}")

    config = load_config(args.config)
    for name in filter(None, args.disable.split(",")):
        if name not in STAGE_NAMES:
            raise SystemExit(f"unknown stage {name!r}; stages: {', '.join(STAGE_NAMES)}")
        config.setdefault("stages", {}).setdefault(name, {})["enabled"] = False
    result = benchmark(
        args.video, runs=args.runs, config=config, device=detect_device(args.device),
        corners=args.corners, referee=args.referee,
    )  # fmt: skip
    print(to_markdown(result))
    write_report(result, args.out)
    print(f"wrote {args.out} and {args.out.with_suffix('.json')}")


if __name__ == "__main__":
    main()
