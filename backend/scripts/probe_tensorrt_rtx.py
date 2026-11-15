"""Isolated TensorRT RTX pose-model experiment; does not alter application providers.

Run with a separate environment containing ONNX Runtime GPU and the NVIDIA
TensorRT RTX EP. The input NPZ should contain ``inputs``, ``out0`` and ``out1``
produced by the application's CUDA provider for the same model.
"""
from __future__ import annotations

import argparse
import statistics
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
import onnxruntime_ep_nv_tensorrt_rtx as trt_ep


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=20)
    args = parser.parse_args()
    data = np.load(args.data)
    tensor = data["inputs"]
    ort.register_execution_provider_library(trt_ep.get_ep_name(), trt_ep.get_library_path())
    devices = [d for d in ort.get_ep_devices() if d.ep_name == "NvTensorRTRTXExecutionProvider"]
    if not devices:
        raise RuntimeError("TensorRT RTX provider is not available")
    # Inspect the model using CPU first to determine its real symbolic input name.
    inspect = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    input_name = inspect.get_inputs()[0].name
    shape = "x".join(map(str, tensor.shape))
    profile = f"{input_name}:{shape}"
    opts = ort.SessionOptions()
    opts.add_session_config_entry("session.record_ep_graph_assignment_info", "1")
    opts.add_provider_for_devices(devices, {"nv_profile_min_shapes": profile,
                                            "nv_profile_opt_shapes": profile,
                                            "nv_profile_max_shapes": profile})
    start = time.perf_counter()
    session = ort.InferenceSession(str(args.model), sess_options=opts)
    print(f"session setup: {time.perf_counter() - start:.3f}s, profile={profile}", flush=True)
    print(f"providers: {session.get_providers()}")
    print(f"graph assignments: {session.get_provider_graph_assignment_info()}")
    times = []
    for _ in range(args.runs + 2):
        start = time.perf_counter()
        results = session.run(None, {input_name: tensor})
        times.append((time.perf_counter() - start) * 1000)
    print(f"first={times[0]:.1f}ms warm median={statistics.median(times[2:]):.1f}ms")
    for i, result in enumerate(results):
        baseline = data[f"out{i}"]
        print(f"output {i}: max absolute difference {np.max(np.abs(result - baseline)):.8g}")


if __name__ == "__main__":
    main()
