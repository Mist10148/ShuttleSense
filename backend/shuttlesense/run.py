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


CORNER_NAMES = ("near-left", "near-right", "far-right", "far-left")


def click_corners(video: Path, frame_index: int = 0) -> list[list[float]]:
    """Open a window on one frame and collect 4 corner clicks (Backspace undoes, Esc quits).

    Needs an OpenCV build with GUI support (pip install opencv-python); the headless wheel
    used by the server cannot open windows.
    """
    import cv2

    from shuttlesense.court import validate_corners
    from shuttlesense.io import read_frame

    frame = read_frame(video, frame_index)
    if frame is None:
        raise SystemExit(f"cannot read frame {frame_index} of {video}")
    points: list[list[float]] = []
    title = "ShuttleSense calibration"

    def on_mouse(event, x, y, _flags, _param) -> None:
        if event == cv2.EVENT_LBUTTONDOWN and len(points) < 4:
            points.append([float(x), float(y)])

    try:
        cv2.namedWindow(title, cv2.WINDOW_NORMAL)
    except cv2.error as exc:
        raise SystemExit(
            "--calibrate needs OpenCV with GUI support: pip install opencv-python "
            "(or pass --corners)"
        ) from exc
    cv2.setMouseCallback(title, on_mouse)
    while True:
        canvas = frame.copy()
        for i, (x, y) in enumerate(points):
            cv2.circle(canvas, (int(x), int(y)), 6, (0, 255, 255), -1)
            cv2.putText(canvas, str(i + 1), (int(x) + 8, int(y) - 8), 0, 0.7, (0, 255, 255), 2)
        hint = "Enter: done" if len(points) == 4 else f"Click {CORNER_NAMES[len(points)]}"
        cv2.putText(canvas, hint, (12, 30), 0, 0.8, (255, 255, 255), 2)
        cv2.imshow(title, canvas)
        key = cv2.waitKey(30) & 0xFF
        if key == 27:
            cv2.destroyWindow(title)
            raise SystemExit("calibration cancelled")
        if key == 8 and points:
            points.pop()
        if key in (10, 13) and len(points) == 4:
            try:
                validate_corners(points)
            except ValueError as exc:
                print(f"{exc}; click them again")
                points.clear()
                continue
            cv2.destroyWindow(title)
            return points


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
        "--stroke-model",
        choices=["cnn", "lstm", "rf"],
        default=None,
        help="stroke classifier: 1D CNN, LSTM or Random Forest (default: pipeline YAML)",
    )
    p.add_argument(
        "--tracking-csv", type=Path, help="use a TrackNetV3 predict.py CSV instead of the model"
    )
    p.add_argument(
        "--fake", action="store_true", help="return the golden record instead of running models"
    )
    return p


def main(argv: list[str] | None = None) -> None:
    args = build_parser().parse_args(argv)
    if args.calibrate:
        args.corners = click_corners(args.video)
        print("corners: " + ",".join(f"{v:.0f}" for c in args.corners for v in c))

    def report(name: str, status: str, progress: float) -> None:
        if status in ("running", "pending") and progress not in (0.0, 1.0):
            return
        print(f"[{name:<9}] {status}")

    config = load_config(args.config)
    if args.stroke_model:
        from shuttlesense.config import with_stroke_model

        config = with_stroke_model(config, args.stroke_model)
    if args.tracking_csv:
        stages = config.setdefault("stages", {})
        stages.setdefault("tracking", {})["precomputed_csv"] = str(args.tracking_csv.resolve())
    pipeline = run_pipeline
    if args.fake:
        from shuttlesense.fake import fake_pipeline

        pipeline = fake_pipeline
    record = pipeline(
        args.video,
        args.out,
        clip_id=args.video.stem,
        config=config,
        court_corners_px=args.corners,
        overlays=args.overlays,
        referee_enabled=not args.no_referee,
        device=detect_device(args.device),
        on_event=report,
    )
    print(f"{record.num_frames} frames, {len(record.hits)} hits -> {args.out}")


if __name__ == "__main__":
    main()
