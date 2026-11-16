"""Compare TrackNet CUDA and TensorRT RTX on real Watch inputs, without changing Watch."""

from __future__ import annotations

import argparse
import statistics
import time
from collections import deque
from pathlib import Path
from types import SimpleNamespace

import cv2
import numpy as np
import onnxruntime as ort
import torch

from shuttlesense.config import BACKEND_DIR
from shuttlesense.io import FrameReader
from shuttlesense.pose.watch_acceleration import _rtx_session
from shuttlesense.tracking.postprocess import heatmap_to_xy
from shuttlesense.tracking.tracknet import INPUT_SIZE, _load_model, _track_input_rgb


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True)
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--start-frame", type=int, default=0)
    args = parser.parse_args()
    weights = BACKEND_DIR / "weights/tracknet/TrackNet_best.pt"
    model, seq_len, bg_mode = _load_model(weights, "cuda", "tracknet")
    channels = model.down_block_1.conv_1.conv.in_channels
    sample = torch.zeros((1, channels, INPUT_SIZE[1], INPUT_SIZE[0]), device="cuda")
    cache = BACKEND_DIR / ".cache" / "tracknet_rtx_probe"
    cache.mkdir(parents=True, exist_ok=True)
    model_path = cache / "tracknet.onnx"

    class Latest(torch.nn.Module):
        def __init__(self, network):
            super().__init__()
            self.network = network

        def forward(self, value):
            return self.network(value)[:, -1:]

    with torch.inference_mode(), torch.autocast("cuda"):
        torch.onnx.export(
            Latest(model).eval(),
            (sample,),
            str(model_path),
            input_names=["input"],
            output_names=["heatmaps"],
            opset_version=17,
            dynamo=False,
        )
    spec = SimpleNamespace(name="input", shape=list(sample.shape))
    model_info = SimpleNamespace(
        onnx_model=str(model_path), session=SimpleNamespace(get_inputs=lambda: [spec])
    )
    start = time.perf_counter()
    session, assignments = _rtx_session(model_info, 1, False, cache / "engines")
    cuda_onnx = ort.InferenceSession(
        str(model_path), providers=["CUDAExecutionProvider", "CPUExecutionProvider"]
    )
    host_session, _ = _rtx_session(model_info, 1, False, cache / "engines")
    print(f"setup={time.perf_counter() - start:.2f}s; assignment={assignments}", flush=True)
    # CUDA Graph replay can retain addresses: keep both the tensor and binding alive.
    stable = torch.empty_like(sample)
    binding = session.io_binding()
    binding.bind_input("input", "cuda", 0, np.float32, tuple(stable.shape), stable.data_ptr())
    binding.bind_output("heatmaps", "cuda")
    samples, window = [], deque(maxlen=seq_len)
    names = ("onnx_cuda", "rtx_host", "rtx_stable_gpu")
    times = {name: [] for name in ("pytorch", *names)}
    differences = {
        name: {"max_heatmap": 0.0, "points": 0, "visibility": 0, "max_point_px": 0.0}
        for name in names
    }
    visible = 0
    source = FrameReader(args.video).frames(args.start_frame, args.start_frame + args.frames)
    for _, frame in source:
        ok, jpeg = cv2.imencode(".jpg", frame)
        if not ok:
            raise RuntimeError("JPEG encode failed")
        frame = cv2.imdecode(jpeg, cv2.IMREAD_COLOR)
        rgb = cv2.resize(frame[:, :, ::-1], INPUT_SIZE)
        if len(samples) < 30:
            samples.append(rgb)
        median = np.median(np.stack(samples), axis=0).astype(np.uint8)
        window.append(rgb)
        frames = [window[0]] * (seq_len - len(window)) + list(window)
        array = _track_input_rgb(frames, bg_mode, median)[None]
        stable.copy_(torch.from_numpy(array))
        torch.cuda.synchronize()
        start = time.perf_counter()
        with torch.inference_mode(), torch.autocast("cuda"):
            expected = model(stable)[:, -1:].float().cpu().numpy()
        times["pytorch"].append((time.perf_counter() - start) * 1000)
        expected_point = heatmap_to_xy(expected[0, 0])
        visible += int(bool(expected_point[2]))
        for name in names:
            start = time.perf_counter()
            if name == "rtx_stable_gpu":
                session.run_with_iobinding(binding)
                actual = binding.copy_outputs_to_cpu()[0]
            else:
                target = cuda_onnx if name == "onnx_cuda" else host_session
                actual = target.run(None, {"input": array})[0]
            times[name].append((time.perf_counter() - start) * 1000)
            actual = actual.astype(np.float32)
            point = heatmap_to_xy(actual[0, 0])
            row = differences[name]
            row["max_heatmap"] = max(row["max_heatmap"], float(np.max(np.abs(expected - actual))))
            row["points"] += int(expected_point != point)
            row["visibility"] += int(expected_point[2] != point[2])
            if expected_point[2] and point[2]:
                delta = np.subtract(expected_point[:2], point[:2])
                row["max_point_px"] = max(row["max_point_px"], float(np.linalg.norm(delta)))
    count = len(times["pytorch"])
    warm = min(10, count // 4)
    print(f"frames={count}; visible={visible}; point errors in 512x288 model pixels")
    print(f"differences: {differences}")
    for name, values in times.items():
        print(
            f"{name}: median={statistics.median(values[warm:]):.2f}ms "
            f"total={sum(values[warm:]) / 1000:.2f}s"
        )


if __name__ == "__main__":
    main()
