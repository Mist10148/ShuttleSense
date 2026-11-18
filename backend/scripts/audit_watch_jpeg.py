"""Measure the pixel changes caused by frame-by-frame Watch's JPEG round trip."""

from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path

import cv2
import numpy as np

from shuttlesense.io import FrameReader


def audit(reader: FrameReader, limit: int) -> dict:
    if limit < 1:
        raise ValueError("frame limit must be positive")
    pixels = changed = absolute_error = 0
    max_error = 0
    sizes, encode_ms, decode_ms = [], [], []
    for _, frame in reader.frames(0, limit):
        started = time.perf_counter()
        ok, jpeg = cv2.imencode(".jpg", frame)
        encode_ms.append((time.perf_counter() - started) * 1000)
        if not ok:
            raise ValueError("JPEG encoding failed")
        started = time.perf_counter()
        decoded = cv2.imdecode(jpeg, cv2.IMREAD_COLOR)
        decode_ms.append((time.perf_counter() - started) * 1000)
        if decoded is None or decoded.shape != frame.shape:
            raise ValueError("JPEG round trip failed or changed frame shape")
        difference = np.abs(frame.astype(np.int16) - decoded.astype(np.int16))
        pixels += difference.size
        changed += int(np.count_nonzero(difference))
        absolute_error += int(difference.sum())
        max_error = max(max_error, int(difference.max()))
        sizes.append(int(jpeg.nbytes))
    if not sizes:
        raise ValueError("video has no readable frames")
    return {
        "frames": len(sizes),
        "normalized_size": [reader.width, reader.height],
        "normalized_fps": reader.fps,
        "changed_channel_values_percent": round(100 * changed / pixels, 3),
        "mean_absolute_channel_error": round(absolute_error / pixels, 3),
        "max_absolute_channel_error": max_error,
        "median_jpeg_bytes": int(statistics.median(sizes)),
        "median_encode_ms": round(statistics.median(encode_ms), 3),
        "median_decode_ms": round(statistics.median(decode_ms), 3),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=50)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--max-fps", type=float, default=30.0)
    args = parser.parse_args()
    reader = FrameReader(args.video, target_height=args.height, max_fps=args.max_fps)
    print(json.dumps(audit(reader, args.frames), indent=2))


if __name__ == "__main__":
    main()
