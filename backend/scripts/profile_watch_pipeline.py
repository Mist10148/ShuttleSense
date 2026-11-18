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
    parser.add_argument(
        "--wall-seconds", type=float, help="stop processing after this many wall-clock seconds"
    )
    parser.add_argument("--start-frame", type=int, default=0)
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    parser.add_argument("--court", choices=["singles", "doubles"], default="singles")
    parser.add_argument("--corners", type=float, nargs=8)
    parser.add_argument("--record", action="store_true")
    parser.add_argument(
        "--decoded-frames", action="store_true", help="bypass the background Watch JPEG round trip"
    )
    parser.add_argument(
        "--ort-threads",
        type=int,
        default=0,
        help="experiment with a smaller ONNX Runtime CPU thread pool",
    )
    parser.add_argument(
        "--player-provider",
        choices=["cuda", "detector", "pose", "both"],
        default="cuda",
        help="experimental TensorRT RTX model selection",
    )
    parser.add_argument(
        "--pose-batch-size", type=int, choices=range(1, 17), help="override Watch pose batch size"
    )
    parser.add_argument(
        "--pose-opt-batch",
        type=int,
        choices=range(1, 17),
        help="override TensorRT RTX pose optimal batch shape",
    )
    parser.add_argument(
        "--shadow-margin",
        type=float,
        help="observe a tighter candidate margin without changing selection",
    )
    parser.add_argument(
        "--shadow-footpoint",
        action="store_true",
        help="observe footpoint-based candidate filtering without excluding",
    )
    parser.add_argument("--nvtx", action="store_true", help="add NVTX ranges for Nsight Systems")
    parser.add_argument(
        "--gpu-window", action="store_true", help="experiment with GPU shuttle input"
    )
    parser.add_argument("--track-provider", choices=["pytorch", "rtx"], default="pytorch")
    parser.add_argument(
        "--pose-crop-lookup",
        action="store_true",
        help="experiment with lookup-table pose crop normalization",
    )
    parser.add_argument(
        "--split-detector",
        action="store_true",
        help="experiment with the TensorRT / CUDA split detector",
    )
    parser.add_argument(
        "--pose-breakdown",
        action="store_true",
        help="measure pose crop, inference and postprocessing calls",
    )
    parser.add_argument(
        "--detector-breakdown",
        action="store_true",
        help="measure detector preprocessing, inference and postprocessing",
    )
    args = parser.parse_args()
    setup_start = time.perf_counter()
    config = with_court(load_config(), args.court)
    config = {
        **config,
        "watch": {
            **config.get("watch", {}),
            "player_provider": args.player_provider,
            "candidate_shadow_margin_m": args.shadow_margin,
            "candidate_shadow_footpoint": args.shadow_footpoint,
        },
    }
    config["watch"]["track_gpu_window"] = args.gpu_window
    config["watch"]["track_provider"] = args.track_provider
    config["watch"]["pose_crop_lookup"] = args.pose_crop_lookup
    config["watch"]["split_detector"] = args.split_detector
    if args.pose_batch_size is not None:
        config["watch"]["pose_batch_size"] = args.pose_batch_size
    if args.pose_opt_batch is not None:
        config["watch"]["pose_opt_batch"] = args.pose_opt_batch
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
                component.onnx_model,
                sess_options=options,
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
            if args.nvtx:
                import torch

                torch.cuda.nvtx.range_push(label)
            try:
                return original(*a, **kw)
            finally:
                if args.nvtx:
                    torch.cuda.nvtx.range_pop()
                timings[label].append((time.perf_counter() - start) * 1000)

        setattr(obj, name, wrapped)

    measure(model, "_shuttle", "shuttle")
    measure(model, "_players", "players")
    measure(model.far_refiner, "refine", "far_refinement")
    measure(model.tracker, "update", "tracker_update")
    if args.pose_breakdown or args.detector_breakdown:
        import inspect

        detector = getattr(model, "watch_detect", None)
        if detector is None:
            raise RuntimeError("pose breakdown needs a Watch candidate detector")
        closure = inspect.getclosurevars(detector).nonlocals
        body = closure["body"]
        if args.pose_breakdown:
            for method, label in (("preprocess", "pose_crop"), ("postprocess", "pose_post")):
                measure(body.pose_model, method, label)
            pose_session = body.pose_model.session
            original_run = pose_session.run

            def record_batch(*a, **kw):
                feed = a[1] if len(a) > 1 else kw.get("input_feed", {})
                if feed:
                    timings["pose_batch_size"].append(next(iter(feed.values())).shape[0])
                return original_run(*a, **kw)

            pose_session.run = record_batch
            measure(pose_session, "run", "pose_run")
            lookup = closure.get("lookup")
            if lookup is not None:
                measure(lookup, "prepare", "pose_lookup")
        if args.detector_breakdown:
            for method, label in (
                ("preprocess", "detector_pre"),
                ("inference", "detector_run"),
                ("postprocess", "detector_post"),
            ):
                measure(body.det_model, method, label)
    parallel = ParallelWatchPerception(model)
    with tempfile.TemporaryDirectory(prefix="shuttlesense-profile-") as temp:
        recording = Path(temp) / "recording.mp4" if args.record else None
        request = StartRequest(
            fps=reader.fps,
            width=reader.width,
            height=reader.height,
            court=args.court,
            corners=corners,
        )
        session = LiveSession(
            session_id="profile",
            request=request,
            config=config,
            perception=parallel,
            court_corners=corners,
            recording=recording,
            device=device,
        )
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
        print(f"setup={time.perf_counter() - setup_start:.2f}s", flush=True)
        run_start = time.perf_counter()
        frames = iter(reader.frames(args.start_frame, args.start_frame + args.frames))
        try:
            while True:
                if (
                    args.wall_seconds is not None
                    and time.perf_counter() - run_start >= args.wall_seconds
                ):
                    break
                start = time.perf_counter()
                item = next(frames, None)
                timings["read"].append((time.perf_counter() - start) * 1000)
                if item is None:
                    break
                i, frame = item
                index = i - args.start_frame
                ts = index * 1000.0 / reader.fps
                if not args.decoded_frames:
                    start = time.perf_counter()
                    ok, jpeg = cv2.imencode(".jpg", frame)
                    if not ok:
                        raise RuntimeError("JPEG encode failed")
                    timings["encode"].append((time.perf_counter() - start) * 1000)
                    packet = HEADER.pack(index, ts) + jpeg.tobytes()
                start = time.perf_counter()
                if args.decoded_frames:
                    with session.lock:
                        session.process(frame, index, ts, time.monotonic())
                else:
                    _frames(session, [(packet, time.monotonic())])
                timings["frame"].append((time.perf_counter() - start) * 1000)
        finally:
            frames.close()
            parallel.close()
            close_start = time.perf_counter()
            session.close()
            close_s = time.perf_counter() - close_start
        elapsed = time.perf_counter() - run_start
    count = len(timings["frame"])
    print(
        f"device={device}, frames={count}, recording={args.record}, "
        f"decoded_frames={args.decoded_frames}"
    )
    print(
        f"processing_wall={elapsed:.2f}s, throughput={count / elapsed:.2f} fps, "
        f"recording_close={close_s:.2f}s, video_duration={count / reader.fps:.2f}s"
    )
    print("Frame timings include inference warmup; shuttle and player work may overlap.")
    for name, values in timings.items():
        if values and name != "pose_batch_size":
            p95 = sorted(values)[math.ceil(len(values) * 0.95) - 1]
            print(
                f"{name:14s} count={len(values):4d} total={sum(values) / 1000:8.2f}s "
                f"mean={statistics.mean(values):7.1f}ms "
                f"median={statistics.median(values):7.1f}ms p95={p95:7.1f}ms"
            )
    if timings["pose_batch_size"]:
        from collections import Counter

        print(f"pose batch sizes: {dict(sorted(Counter(timings['pose_batch_size']).items()))}")
    candidates = getattr(model, "watch_candidates", None)
    if candidates is not None:
        print(f"candidate diagnostics: {candidates.stats}")
        if candidates.proposal is not None:
            print(f"candidate proposal: {candidates.proposal_stats}")
    print(f"provider diagnostics: {getattr(model, 'provider_diagnostics', 'CUDA baseline')}")
    print(f"shuttle provider: {getattr(model, 'track_provider_diagnostics', 'PyTorch baseline')}")


if __name__ == "__main__":
    main()
