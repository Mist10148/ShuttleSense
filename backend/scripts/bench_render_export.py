"""Benchmark a saved Watch record using the normal renderer and video writer.

PSNR compares decoded output to the same freshly drawn BGR frames. Results are
diagnostic; ffmpeg launch is asynchronous and pipe writes include conversion.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import threading
import time
from pathlib import Path

import cv2
import numpy as np
import psutil
from bench_watch_complete import ResourceSampler

from shuttlesense.io import FrameReader
from shuttlesense.render import OVERLAYS, RenderState, style
from shuttlesense.render.overlays import draw_frame
from shuttlesense.render.writer import VideoWriter
from shuttlesense.schema import load_record


class ChildSampler:
    """Sample process/FFmpeg memory and CPU; short-lived peaks can be missed."""

    def __init__(self):
        self.process = psutil.Process()
        self.stop = threading.Event()
        self.rows = []
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def sample(self):
        processes = {}
        while not self.stop.wait(0.2):
            for process in [self.process, *self.process.children(recursive=True)]:
                try:
                    if process.pid not in processes:
                        process.cpu_percent(None)
                        processes[process.pid] = process
                    process = processes[process.pid]
                    cpu = process.cpu_percent(None)
                    self.rows.append(
                        (process.pid == self.process.pid, process.memory_info().rss, cpu)
                    )
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        self.thread.join()

    def summary(self):
        return {label: {"rss_max_bytes": max((r[1] for r in self.rows if r[0] == is_parent),
                                              default=None),
                        "cpu_percent_max": max((r[2] for r in self.rows if r[0] == is_parent),
                                               default=None)}
                for label, is_parent in (("benchmark", True), ("child", False))}


def probe(path, expected, fps):
    executable = shutil.which("ffprobe")
    if executable is None:
        return {"available": False}
    output = subprocess.check_output([
        executable, "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=codec_name,pix_fmt,width,height,avg_frame_rate,nb_frames:"
        "frame=best_effort_timestamp_time", "-of", "json", str(path)
    ], text=True)
    data = json.loads(output)
    stamps = [float(f["best_effort_timestamp_time"]) for f in data.get("frames", [])
              if "best_effort_timestamp_time" in f]
    offsets = [abs(t - i / fps) for i, t in enumerate(stamps)]
    return {"available": True, "stream": data.get("streams", []),
            "timestamp_count": len(stamps), "expected_frames": expected,
            "strictly_increasing": all(a < b for a, b in zip(stamps, stamps[1:], strict=False)),
            "max_timestamp_offset_s": max(offsets, default=None)}


def quality(path, reader, record, count):
    capture = cv2.VideoCapture(str(path))
    if not capture.isOpened():
        raise RuntimeError(f"Cannot decode {path}")
    state = RenderState(config={}, scale=style.scale_for(record.height))
    squared, values, decoded = 0, 0, 0
    try:
        for i, image in reader.frames(0, count):
            ok, actual = capture.read()
            if not ok:
                break
            expected = draw_frame(image, record, i, OVERLAYS, state)
            if actual.shape != expected.shape:
                raise RuntimeError("Decoded frame dimensions differ from reference")
            difference = actual.astype(np.int16) - expected.astype(np.int16)
            squared += int(np.sum(difference.astype(np.int32) ** 2, dtype=np.int64))
            values += difference.size
            decoded += 1
        extra, _ = capture.read()
    finally:
        capture.release()
    mse = squared / values if values else None
    return {"decoded_frames": decoded, "extra_frame": bool(extra),
            "psnr_db": None if not mse else 10 * math.log10(255**2 / mse),
            "mse": mse}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--frames", type=int, required=True)
    parser.add_argument("--codec", choices=("libx264", "h264_nvenc"), required=True)
    parser.add_argument("--quality", type=int, default=23)
    parser.add_argument("--repeats", type=int, default=2)
    args = parser.parse_args()
    if min(args.frames, args.repeats) <= 0:
        parser.error("frames and repeats must be positive")
    record = load_record(args.record.read_text(encoding="utf8"))
    reader = FrameReader(args.video, target_height=record.height, max_fps=record.fps)
    if min(len(record.frames), len(reader)) < args.frames:
        parser.error("record or video is shorter than requested")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for repeat in range(args.repeats):
        path = args.out_dir / f"{args.codec}_q{args.quality}_{args.frames}_{repeat}.mp4"
        state = RenderState(config={}, scale=style.scale_for(record.height))
        writer = VideoWriter(path, fps=record.fps, size=(record.width, record.height),
                             codec=args.codec, crf=args.quality)
        times = {"reader_next_s": 0.0, "draw_s": 0.0, "write_s": 0.0}
        with ResourceSampler() as system, ChildSampler() as processes:
            start = time.perf_counter()
            with writer:
                times["writer_enter_s"] = time.perf_counter() - start
                frames = iter(reader.frames(0, args.frames))
                for i in range(args.frames):
                    before = time.perf_counter()
                    index, image = next(frames)
                    times["reader_next_s"] += time.perf_counter() - before
                    if index != i:
                        raise RuntimeError("Nonconsecutive source frames")
                    before = time.perf_counter()
                    draw_frame(image, record, index, OVERLAYS, state)
                    times["draw_s"] += time.perf_counter() - before
                    before = time.perf_counter()
                    writer.write(image)
                    elapsed = time.perf_counter() - before
                    times["write_s"] += elapsed
                    if i == 0:
                        times["first_write_s"] = elapsed
                frames.close()
                before_exit = time.perf_counter()
            times["writer_exit_s"] = time.perf_counter() - before_exit
            times["total_s"] = time.perf_counter() - start
        result = {"codec_requested": args.codec, "codec_active": writer.codec,
                  "backend": writer.backend, "quality_setting": args.quality,
                  "frames": writer.frames,
                  "repeat": repeat, "size_bytes": path.stat().st_size, "timing": times,
                  "resources": system.summary(), "processes": processes.summary(),
                  "probe": probe(path, args.frames, record.fps),
                  "quality": quality(path, reader, record, args.frames)}
        print("RESULT " + json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
