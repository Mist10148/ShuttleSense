"""Compare original and lookup-table pose crops on detected video people."""

from __future__ import annotations

import argparse
import inspect
import statistics
import time
from pathlib import Path

import cv2
import numpy as np
import torch  # noqa: F401  # preload CUDA libraries used by ONNX Runtime

from shuttlesense.io import FrameReader
from shuttlesense.pose.estimator import _rtmlib_detector
from shuttlesense.pose.watch_preprocess import PoseCropLookup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=60)
    args = parser.parse_args()
    detector = _rtmlib_detector("balanced", "cuda")
    body = inspect.getclosurevars(detector).nonlocals["body"]
    if "CUDAExecutionProvider" not in body.det_model.session.get_providers():
        raise RuntimeError("CUDA detector provider is unavailable")
    pose, optimized = body.pose_model, PoseCropLookup(body.pose_model)
    original_times, lookup_times, crops, mismatch = [], [], 0, 0
    for _, frame in FrameReader(args.video).frames(0, args.frames):
        ok, jpeg = cv2.imencode(".jpg", frame)
        if not ok:
            raise RuntimeError("JPEG encode failed")
        frame = cv2.imdecode(jpeg, cv2.IMREAD_COLOR)
        boxes = body.det_model(frame)
        if not len(boxes):
            continue
        for start in range(0, len(boxes), 8):
            selected = boxes[start : start + 8]
            t = time.perf_counter()
            prepared = [pose.preprocess(frame, box) for box in selected]
            expected = np.stack(
                [
                    np.ascontiguousarray(img.transpose(2, 0, 1), dtype=np.float32)
                    for img, _, _ in prepared
                ]
            )
            original_times.append((time.perf_counter() - t) * 1000)
            t = time.perf_counter()
            actual, geometry = optimized.prepare(frame, selected)
            lookup_times.append((time.perf_counter() - t) * 1000)
            crops += len(selected)
            mismatch += int(not np.array_equal(expected, actual))
            mismatch += sum(
                not np.array_equal(center, original[1]) or not np.array_equal(scale, original[2])
                for (center, scale), original in zip(geometry, prepared, strict=True)
            )
    print(f"frames={args.frames}, crops={crops}, mismatched batches/geometries={mismatch}")
    for name, values in (("original", original_times), ("lookup", lookup_times)):
        print(
            f"{name}: chunks={len(values)}, median={statistics.median(values):.2f}ms, "
            f"total={sum(values) / 1000:.2f}s"
        )
    print("Isolated CPU crop timings; not a full Watch benchmark.")


if __name__ == "__main__":
    main()
