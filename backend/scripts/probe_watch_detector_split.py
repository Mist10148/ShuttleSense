"""Experiment: split YOLOX before unsupported TopK; never changes Watch settings."""
from __future__ import annotations

import argparse
import inspect
import statistics
import time
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np
import onnx
import onnxruntime as ort
import torch  # noqa: F401  # preload CUDA libraries used by ORT
from scipy.optimize import linear_sum_assignment

from shuttlesense.io import FrameReader
from shuttlesense.pose.estimator import _rtmlib_detector
from shuttlesense.pose.watch_acceleration import _rtx_session

BOUNDARY = ["1436", "1438", "1443"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=80)
    parser.add_argument("--start-frame", type=int, default=0)
    args = parser.parse_args()
    detect = _rtmlib_detector("balanced", "cuda")
    body = inspect.getclosurevars(detect).nonlocals["body"]
    model = body.det_model
    graph = onnx.shape_inference.infer_shapes(onnx.load(model.onnx_model))
    extract = onnx.utils.Extractor(graph)
    cache = Path(".cache/watch_detector_split")
    cache.mkdir(parents=True, exist_ok=True)
    front_path, post_path = cache / "front.onnx", cache / "post.onnx"
    onnx.save(extract.extract_model([graph.graph.input[0].name], BOUNDARY), front_path)
    onnx.save(extract.extract_model(BOUNDARY, [x.name for x in graph.graph.output]), post_path)
    original = SimpleNamespace(session=model.session, onnx_model=str(front_path))
    start = time.perf_counter()
    front, assignments = _rtx_session(original, 1, False, cache / "engines")
    post = ort.InferenceSession(
        str(post_path), providers=["CUDAExecutionProvider", "CPUExecutionProvider"]
    )
    print(f"setup: {time.perf_counter() - start:.2f}s; assignments: {assignments}", flush=True)
    original_times, split_times, different, max_delta, count_changes = [], [], 0, 0.0, 0
    reader = FrameReader(args.video)
    for _, frame in reader.frames(args.start_frame, args.start_frame + args.frames):
        jpeg_ok, jpeg = cv2.imencode(".jpg", frame)
        if not jpeg_ok:
            raise RuntimeError("JPEG encode failed")
        frame = cv2.imdecode(jpeg, cv2.IMREAD_COLOR)
        image, ratio = model.preprocess(frame)
        tensor = np.ascontiguousarray(image.transpose(2, 0, 1), dtype=np.float32)[None]
        start = time.perf_counter()
        baseline = model.session.run(None, {model.session.get_inputs()[0].name: tensor})
        original_times.append((time.perf_counter() - start) * 1000)
        start = time.perf_counter()
        io = front.io_binding()
        io.bind_cpu_input(front.get_inputs()[0].name, tensor)
        for name in BOUNDARY:
            io.bind_output(name, "cuda")
        front.run_with_iobinding(io)
        post_io = post.io_binding()
        for name, value in zip(BOUNDARY, io.get_outputs(), strict=True):
            post_io.bind_ortvalue_input(name, value)
        for output in post.get_outputs():
            post_io.bind_output(output.name, "cpu")
        post.run_with_iobinding(post_io)
        actual = post_io.copy_outputs_to_cpu()
        split_times.append((time.perf_counter() - start) * 1000)
        boxes_a = model.postprocess(baseline[0], ratio)
        boxes_b = model.postprocess(actual[0], ratio)
        if boxes_a.shape != boxes_b.shape:
            different += 1
            count_changes += 1
        else:
            if boxes_a.size:
                cost = np.max(np.abs(boxes_a[:, None, :] - boxes_b[None, :, :]), axis=2)
                rows, cols = linear_sum_assignment(cost)
                delta = float(cost[rows, cols].max())
            else:
                delta = 0.0
            max_delta = max(max_delta, delta)
            different += int(delta > 0.01)
    warm = min(10, len(original_times) // 4)
    print(f"frames={len(original_times)}; count changes={count_changes}; "
          f"frames with matched box delta > 0.01px={different}; "
          f"max box/score delta={max_delta:.6g}")
    for name, values in (("CUDA", original_times[warm:]), ("split", split_times[warm:])):
        print(f"{name}: median={statistics.median(values):.2f}ms total={sum(values)/1000:.3f}s")


if __name__ == "__main__":
    main()
