"""Command-line entry point: python -m shuttlesense.run --video clip.mp4 --out outputs/clip."""

from __future__ import annotations

import argparse
from pathlib import Path

from shuttlesense.config import detect_device, load_config
from shuttlesense.pipeline import run_pipeline
from shuttlesense.render import OVERLAYS


def parse_corners(text: str) -> list[list[float]]:
    values = [float(v) for v in text.split(",")]
    if len(values) != 8:
        raise argparse.ArgumentTypeError("--corners needs 8 numbers: x1,y1,x2,y2,x3,y3,x4,y4")
    return [values[i : i + 2] for i in range(0, 8, 2)]


def parse_overlays(text: str) -> list[str]:
    names = [n.strip() for n in text.split(",") if n.strip()]
    unknown = sorted(set(names) - set(OVERLAYS))
    if unknown:
        raise argparse.ArgumentTypeError(f"unknown overlays: {', '.join(unknown)}")
    return names


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="shuttlesense", description="Analyze a badminton rally video.")
    p.add_argument("--video", type=Path, required=True, help="input video (MP4/MOV/AVI)")
    p.add_argument("--out", type=Path, required=True, help="output folder")
    p.add_argument("--corners", type=parse_corners, help="court corners x1,y1,...,x4,y4")
    p.add_argument("--calibrate", action="store_true", help="click the 4 court corners in a window")
    p.add_argument("--overlays", type=parse_overlays, default=list(OVERLAYS))
    p.add_argument("--no-referee", action="store_true", help="skip the P3 referee layer")
    p.add_argument("--config", type=Path, default=None, help="pipeline YAML")
    p.add_argument("--device", choices=["cpu", "cuda"], default=None)
    p.add_argument(
        "--fake", action="store_true", help="return the golden record instead of running models"
    )
    return p


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    if args.calibrate:
        # TODO(T5.1): OpenCV window on frame 0 to click corners for CLI users.
        raise SystemExit("--calibrate is not implemented yet; pass --corners instead")

    def report(name: str, status: str, progress: float) -> None:
        if status in ("running", "pending") and progress not in (0.0, 1.0):
            return
        print(f"[{name:<9}] {status}")

    pipeline = run_pipeline
    if args.fake:
        from shuttlesense.fake import fake_pipeline

        pipeline = fake_pipeline
    record = pipeline(
        args.video,
        args.out,
        clip_id=args.video.stem,
        config=load_config(args.config),
        court_corners_px=args.corners,
        overlays=args.overlays,
        referee_enabled=not args.no_referee,
        device=detect_device(args.device),
        on_event=report,
    )
    print(f"{record.num_frames} frames, {len(record.hits)} hits -> {args.out}")


if __name__ == "__main__":
    main()
