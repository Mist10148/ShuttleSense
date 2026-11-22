"""Compare a one-window batch view with the existing stacked PyTorch input.

This isolated, synchronized experiment does not change Watch or measure Flutter.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
from collections import deque
from pathlib import Path

import cv2
import numpy as np
import torch

from shuttlesense.config import BACKEND_DIR
from shuttlesense.io import FrameReader
from shuttlesense.tracking.postprocess import heatmap_to_xy, scale_to_video
from shuttlesense.tracking.tracknet import INPUT_SIZE, _load_model, _track_input_rgb


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=48)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--warmup", type=int, default=8)
    parser.add_argument("--device", default="cuda")
    args = parser.parse_args()
    if args.frames < 1 or args.repeats < 1 or args.warmup < 0:
        parser.error("frames and repeats must be positive and warmup must be nonnegative")
    model, seq_len, mode = _load_model(
        BACKEND_DIR / "weights/tracknet/TrackNet_best.pt", args.device, "tracknet"
    )
    reader = FrameReader(args.video)
    inputs = []
    backgrounds = []
    window = deque(maxlen=seq_len)
    median = None
    for _, frame in reader.frames(0, args.frames):
        ok, encoded = cv2.imencode(".jpg", frame)
        if not ok:
            raise RuntimeError("JPEG encode failed")
        frame = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
        rgb = cv2.resize(frame[:, :, ::-1], INPUT_SIZE)
        if mode and len(backgrounds) < 30:
            backgrounds.append(rgb)
            median = np.median(np.stack(backgrounds), axis=0).astype(np.uint8)
        window.append(rgb)
        padded = [window[0]] * (seq_len - len(window)) + list(window)
        inputs.append((padded, median))
    if not inputs:
        raise RuntimeError("video contains no readable frames")

    def sync() -> None:
        if args.device.startswith("cuda"):
            torch.cuda.synchronize(args.device)

    timings = {
        name: {"prepare_ms": [], "upload_and_inference_ms": [], "total_ms": []}
        for name in ("stack", "view")
    }
    mismatches = {"input": 0, "heatmap": 0, "point": 0}
    max_heatmap_error = 0.0
    measured = 0
    # Alternate execution order to reduce systematic first/second bias.
    for iteration in range(args.warmup + len(inputs) * args.repeats):
        frames, bg = inputs[iteration % len(inputs)]
        results = {}
        order = ("stack", "view") if iteration % 2 == 0 else ("view", "stack")
        for name in order:
            sync()
            start = time.perf_counter()
            prepared = _track_input_rgb(frames, mode, bg)
            batch = np.stack([prepared]) if name == "stack" else prepared[None, ...]
            prep_end = time.perf_counter()
            with (
                torch.inference_mode(),
                torch.autocast("cuda", enabled=args.device.startswith("cuda")),
            ):
                heatmap = (
                    model(torch.from_numpy(batch).to(args.device))[:, -1:].float().cpu().numpy()
                )
            sync()
            end = time.perf_counter()
            results[name] = (batch, heatmap)
            if iteration >= args.warmup:
                timings[name]["prepare_ms"].append((prep_end - start) * 1000)
                timings[name]["upload_and_inference_ms"].append((end - prep_end) * 1000)
                timings[name]["total_ms"].append((end - start) * 1000)
        if iteration < args.warmup:
            continue
        measured += 1
        reference, candidate = results["stack"], results["view"]
        mismatches["input"] += int(not np.array_equal(reference[0], candidate[0]))
        mismatches["heatmap"] += int(not np.array_equal(reference[1], candidate[1]))
        error = float(np.max(np.abs(reference[1] - candidate[1])))
        max_heatmap_error = max(max_heatmap_error, error)

        def point(heatmap):
            x, y, visible = heatmap_to_xy(heatmap[0, 0])
            if not visible:
                return (0.0, 0.0, 0)
            x, y = scale_to_video(np.array([[x, y]]), INPUT_SIZE, (reader.width, reader.height))[0]
            return (round(float(x), 1), round(float(y), 1), 1)

        mismatches["point"] += int(point(reference[1]) != point(candidate[1]))

    # Repeated baseline inference estimates numerical variation independent of the view.
    aa_mismatches, aa_max_error = 0, 0.0
    for frames, bg in inputs[: min(12, len(inputs))]:
        batch = np.stack([_track_input_rgb(frames, mode, bg)])
        outputs = []
        for _ in range(2):
            with (
                torch.inference_mode(),
                torch.autocast("cuda", enabled=args.device.startswith("cuda")),
            ):
                outputs.append(
                    model(torch.from_numpy(batch).to(args.device))[:, -1:].float().cpu().numpy()
                )
        aa_mismatches += int(not np.array_equal(outputs[0], outputs[1]))
        aa_max_error = max(aa_max_error, float(np.max(np.abs(outputs[0] - outputs[1]))))

    def summary(values):
        return {
            "median": round(statistics.median(values), 3),
            "p95": round(float(np.percentile(values, 95)), 3),
        }

    print(
        json.dumps(
            {
                "frames": len(inputs),
                "repeats": args.repeats,
                "warmup_pairs": args.warmup,
                "measured_pairs": measured,
                "seq_len": seq_len,
                "bg_mode": mode,
                "device": args.device,
                "mismatches": mismatches,
                "max_abs_heatmap_difference": max_heatmap_error,
                "baseline_repeatability": {
                    "pairs": min(12, len(inputs)),
                    "heatmap_mismatches": aa_mismatches,
                    "max_abs_heatmap_difference": aa_max_error,
                },
                "timings_ms": {
                    name: {key: summary(value) for key, value in data.items()}
                    for name, data in timings.items()
                },
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
