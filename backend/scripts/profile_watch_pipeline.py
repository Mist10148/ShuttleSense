"""Profile the actual Watch frame path on a local video, without saving results.

Times for shuttle and players overlap when parallel perception is enabled; they
must not be added together. The optional recording uses a temporary directory.
"""
from __future__ import annotations

import argparse
import contextlib
import math
import statistics
import tempfile
import time
from collections import defaultdict
from pathlib import Path

import cv2

from shuttlesense.api.live import HEADER, _frames
from shuttlesense.config import detect_device, load_config, with_court
from shuttlesense.io import FrameReader
from shuttlesense.stage import StageSkipped
from shuttlesense.stream.perception import ModelPerception, enable_watch_player_continuity
from shuttlesense.stream.session import LiveSession, StartRequest
from shuttlesense.stream.watch_parallel import ParallelWatchPerception
from shuttlesense.strokes import registry
from shuttlesense.strokes.classify import load_classifier


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=100)
    parser.add_argument("--start-frame", type=int, default=0)
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    parser.add_argument("--court", choices=["singles", "doubles"], default="singles")
    parser.add_argument("--corners", type=float, nargs=8)
    parser.add_argument("--record", action="store_true")
    parser.add_argument("--ort-threads", type=int, default=0,
                        help="experiment with a smaller ONNX Runtime CPU thread pool")
    args = parser.parse_args()
    config = with_court(load_config(), args.court)
    device = detect_device(args.device)
    reader = FrameReader(args.video)
    corners = None
    if args.corners:
        sx, sy = reader.width / reader.source.width, reader.height / reader.source.height
        corners = [(args.corners[i] * sx, args.corners[i + 1] * sy) for i in range(0, 8, 2)]
    model = ModelPerception(config, device, (reader.width, reader.height), corners)
    if args.ort_threads:
        import inspect

        import onnxruntime as ort

        body = inspect.getclosurevars(model.detect).nonlocals["body"]
        for component in (body.det_model, body.pose_model):
            options = ort.SessionOptions()
            options.intra_op_num_threads = args.ort_threads
            options.add_session_config_entry("session.intra_op.allow_spinning", "0")
            component.session = ort.InferenceSession(
                component.onnx_model, sess_options=options,
                providers=component.session.get_providers(),
            )
    enable_watch_player_continuity(model)
    if not all(model.available.values()):
        raise RuntimeError(f"Models unavailable: {model.available}")
    timings = defaultdict(list)

    def measure(obj, name, label):
        original = getattr(obj, name)

        def wrapped(*a, **kw):
            start = time.perf_counter()
            try:
                return original(*a, **kw)
            finally:
                timings[label].append((time.perf_counter() - start) * 1000)
        setattr(obj, name, wrapped)

    measure(model, "_shuttle", "shuttle")
    measure(model, "_players", "players")
    measure(model.far_refiner, "refine", "far_refinement")
    parallel = ParallelWatchPerception(model)
    with tempfile.TemporaryDirectory(prefix="shuttlesense-profile-") as temp:
        recording = Path(temp) / "recording.mp4" if args.record else None
        request = StartRequest(fps=reader.fps, width=reader.width, height=reader.height,
                               court=args.court, corners=corners)
        session = LiveSession(session_id="profile", request=request, config=config,
                              perception=parallel, court_corners=corners,
                              recording=recording, device=device)
        session.live["scales"] = [1.0]
        session.analyzer.watch_stroke_guard = True
        stroke_config = session.config.get("stages", {}).get("strokes", {})
        with contextlib.suppress(StageSkipped, ImportError, OSError, ValueError, KeyError):
            _, checkpoint = load_classifier(
                registry.weights_path(stroke_config, registry.algorithm(stroke_config)), device
            )
            session.analyzer.watch_checkpoint = checkpoint
            window = int(checkpoint.get("window_frames", stroke_config.get("window_frames", 32)))
            window_fps = checkpoint.get("window_fps")
            step = reader.fps / float(window_fps) if window_fps else 1.0
            session.analyzer.hit_lag = max(
                session.analyzer.hit_lag, math.ceil((window - 1 - window // 2) * step) + 1
            )
        measure(session, "_decode", "decode")
        measure(session, "_record_frame", "record")
        measure(session.analyzer, "_tick", "analysis_tick")
        try:
            for i, frame in reader.frames(args.start_frame, args.start_frame + args.frames):
                start = time.perf_counter()
                ok, jpeg = cv2.imencode(".jpg", frame)
                if not ok:
                    raise RuntimeError("JPEG encode failed")
                timings["encode"].append((time.perf_counter() - start) * 1000)
                index = i - args.start_frame
                packet = HEADER.pack(index, index * 1000.0 / reader.fps) + jpeg.tobytes()
                start = time.perf_counter()
                _frames(session, [(packet, time.monotonic())])
                timings["frame"].append((time.perf_counter() - start) * 1000)
        finally:
            parallel.close()
            session.close()
    print(f"device={device}, frames={len(timings['frame'])}, recording={args.record}")
    print("Times include startup; shuttle and player work may overlap.")
    for name, values in timings.items():
        if values:
            print(f"{name:14s} count={len(values):4d} total={sum(values)/1000:8.2f}s "
                  f"mean={statistics.mean(values):7.1f}ms "
                  f"median={statistics.median(values):7.1f}ms")
    candidates = getattr(model, "watch_candidates", None)
    if candidates is not None:
        print(f"candidate diagnostics: {candidates.stats}")


if __name__ == "__main__":
    main()
