"""Compare watch-only sequential and concurrent perception on a supplied video.

Run from backend: python scripts/bench_watch_parallel.py --video ../samples/rally01.mp4
Use representative labelled clips to validate accuracy for a given environment.
"""

from __future__ import annotations

import argparse
import contextlib
import statistics
import time
from pathlib import Path

import numpy as np

from shuttlesense.config import detect_device, load_config, with_court
from shuttlesense.io import FrameReader
from shuttlesense.stream.perception import ModelPerception, enable_watch_player_continuity
from shuttlesense.stream.watch_parallel import ParallelWatchPerception


def run(reader, frames, device, parallel, corners=None, court="singles", batch_size=1,
        candidate_filter="off", start_frame=0, jpeg_roundtrip=False, player_provider="cuda"):
    import torch

    base = ModelPerception(with_court(load_config(), court), device,
                           (reader.width, reader.height), corners)
    base.config = {**base.config, "watch": {**base.config.get("watch", {}),
                                            "pose_batch_size": batch_size,
                                            "candidate_filter": candidate_filter,
                                            "player_provider": player_provider}}
    enable_watch_player_continuity(base)
    if not all(base.available.values()):
        raise RuntimeError(f"Models unavailable: {base.available}")
    processor = ParallelWatchPerception(base) if parallel else base
    timings, observations = [], []
    try:
        for index, frame in reader.frames(start_frame, min(len(reader), start_frame + frames)):
            if jpeg_roundtrip:
                import cv2

                ok, encoded = cv2.imencode(".jpg", frame)
                if not ok:
                    raise RuntimeError("JPEG encode failed")
                frame = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
            if device.startswith("cuda"):
                torch.cuda.synchronize()
            started = time.perf_counter()
            shuttle, players = processor(frame, index)
            if device.startswith("cuda"):
                torch.cuda.synchronize()
            timings.append((time.perf_counter() - started) * 1000)
            observations.append((shuttle.model_dump(), players.model_dump()))
    finally:
        if parallel:
            processor.close()
    diagnostics = getattr(base, "watch_candidates", None)
    if player_provider != "cuda":
        print("Provider diagnostics:", getattr(base, "provider_diagnostics", None))
    return timings, observations, dict(diagnostics.stats) if diagnostics else None


def replay_analysis(observations, reader, device, corners, court):
    """Run the same streaming stages over recorded perception outputs."""
    from shuttlesense.court import compute_homography
    from shuttlesense.schema import Court, Players, Shuttle
    from shuttlesense.stage import StageSkipped
    from shuttlesense.stream.analyzer import StreamAnalyzer
    from shuttlesense.strokes import registry
    from shuttlesense.strokes.classify import load_classifier

    config = with_court(load_config(), court)
    mapped = None if corners is None else Court(
        corners_px=tuple(corners), homography=compute_homography(corners).tolist()
    )
    analyzer = StreamAnalyzer(clip_id="comparison", fps=reader.fps, width=reader.width,
                              height=reader.height, court=mapped, config=config, device=device,
                              tick_every=config.get("live", {}).get("tick_every", 5))
    analyzer.watch_stroke_guard = True
    cfg = config.get("stages", {}).get("strokes", {})
    with contextlib.suppress(StageSkipped, FileNotFoundError, ImportError, OSError,
                             ValueError, KeyError):
        _, analyzer.watch_checkpoint = load_classifier(
            registry.weights_path(cfg, registry.algorithm(cfg)), device
        )
    for shuttle, players in observations:
        analyzer.add_frame(Shuttle.model_validate(shuttle), Players.model_validate(players))
    record = analyzer.finalize()
    return {
        "hits": [h.model_dump(mode="json") for h in record.hits],
        "rallies": [r.model_dump(mode="json") for r in record.rallies],
        "line_calls": [c.model_dump(mode="json") for c in record.line_calls],
        "score": record.score.model_dump(mode="json") if record.score else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--start-frame", type=int, default=0)
    parser.add_argument("--device", choices=["cpu", "cuda"], default=None)
    parser.add_argument("--court", choices=["singles", "doubles"], default="singles")
    parser.add_argument("--compare-filter", action="store_true",
                        help="compare unfiltered and prefiltered candidates")
    parser.add_argument("--compare-batch", type=int, default=0,
                        help="compare sequential pose calls with this batch size")
    parser.add_argument("--compare-decoded", action="store_true",
                        help="compare JPEG inputs against decoded source frames")
    parser.add_argument("--compare-provider", choices=["detector", "pose", "both"],
                        help="compare CUDA with a TensorRT RTX provider selection")
    parser.add_argument("--corners", type=float, nargs=8, metavar="PIXEL",
                        help="singles-reference corners in near-left through far-left order")
    args = parser.parse_args()
    reader = FrameReader(args.video)
    device = detect_device(args.device)
    corners = None
    if args.corners:
        sx, sy = reader.width / reader.source.width, reader.height / reader.source.height
        corners = [(args.corners[i] * sx, args.corners[i + 1] * sy) for i in range(0, 8, 2)]
    else:
        print("No court supplied: player tracking outputs cannot be compared.")
    batch_size = args.compare_batch or 1
    if sum(bool(x) for x in (args.compare_decoded, args.compare_batch,
                              args.compare_filter, args.compare_provider)) > 1:
        parser.error("select only one comparison mode")
    watch = load_config().get("watch", {})
    if args.compare_decoded or args.compare_provider:
        batch_size = int(watch.get("pose_batch_size", 1))
    same_watch = bool(args.compare_decoded or args.compare_provider)
    initial_batch = batch_size if args.compare_filter or same_watch else 1
    baseline_filter = (watch.get("candidate_filter", "off") if same_watch else
                       "shadow" if args.compare_filter else "off")
    candidate_filter = (watch.get("candidate_filter", "off") if same_watch else
                        "filter" if args.compare_filter else "off")
    sequential, a, diagnostics = run(reader, args.frames, device,
                                     bool(args.compare_decoded or args.compare_provider),
                                     corners, args.court,
                                     initial_batch,
                                     baseline_filter, args.start_frame,
                                     jpeg_roundtrip=same_watch)
    concurrent, b, filtered = run(reader, args.frames, device,
                                 not (args.compare_batch or args.compare_filter),
                                 corners, args.court, batch_size,
                                 candidate_filter, args.start_frame,
                                 jpeg_roundtrip=bool(args.compare_provider),
                                 player_provider=args.compare_provider or "cuda")
    if not sequential or len(a) != len(b):
        raise SystemExit("Video has too few readable frames")
    # Exclude initial model warmup from timing, but include all frames in comparison.
    warmup = min(10, len(sequential) // 4)
    comparison = (f"TensorRT RTX {args.compare_provider}" if args.compare_provider else
                  "decoded frames" if args.compare_decoded else
                  "filtered candidates" if args.compare_filter else
                  "batched pose" if args.compare_batch else "concurrent")
    if diagnostics is not None:
        print(f"Baseline diagnostics: {diagnostics}")
        print(f"Candidate diagnostics: {filtered}")
    baseline_label = ("JPEG input" if args.compare_decoded else
                      "CUDA baseline" if args.compare_provider else "sequential")
    for label, values in [(baseline_label,
                           sequential[warmup:]),
                          (comparison, concurrent[warmup:])]:
        print(
            f"{label}: median {statistics.median(values):.1f} ms, "
            f"p95 {np.percentile(values, 95):.1f} ms"
        )
    print(f"Frame outputs differing: {sum(x != y for x, y in zip(a, b, strict=True))}/{len(a)}")
    if args.compare_filter or args.compare_decoded or args.compare_provider:
        presence_differences = 0
        max_keypoint_px = 0.0
        for (_, left), (_, right) in zip(a, b, strict=True):
            for name in ("near", "far", "near_2", "far_2"):
                pa, pb = left.get(name), right.get(name)
                if (pa is None) != (pb is None):
                    presence_differences += 1
                elif pa is not None:
                    for ka, kb in zip(pa["keypoints"], pb["keypoints"], strict=True):
                        if min(ka[2], kb[2]) >= .3:
                            max_keypoint_px = max(max_keypoint_px,
                                                  float(np.linalg.norm(np.array(ka[:2]) - kb[:2])))
        if corners:
            print(f"Player presence differences: {presence_differences}; "
                  f"max confident keypoint difference: {max_keypoint_px:.3f} px")
        else:
            print("Player comparisons unavailable without court calibration.")
        original = replay_analysis(a, reader, device, corners, args.court)
        candidate = replay_analysis(b, reader, device, corners, args.court)
        print("Analysis equality:", {key: original[key] == candidate[key] for key in original})
        print("Original analysis counts:", {key: len(original[key]) for key in
                                             ("hits", "rallies", "line_calls")})
        print("Candidate analysis counts:", {key: len(candidate[key]) for key in
                                              ("hits", "rallies", "line_calls")})
        for key in ("hits", "rallies", "line_calls"):
            if original[key] != candidate[key]:
                print(f"{key} baseline:", original[key])
                print(f"{key} candidate:", candidate[key])
    print(
        "Output differences need inspection against labelled footage; "
        "do not infer accuracy from speed."
    )


if __name__ == "__main__":
    main()
