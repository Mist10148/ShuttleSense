"""Experimental TrackNet TensorRT RTX runner with stable device bindings."""

from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import numpy as np

from shuttlesense.tracking.tracknet import INPUT_SIZE


class TrackNetRtx:
    def __init__(self, model, channels, device, cache_dir):
        import torch

        from shuttlesense.pose.watch_acceleration import _rtx_session

        if str(device) not in ("cuda", "cuda:0"):
            raise ValueError("TrackNet TensorRT experiment supports CUDA device 0 only")
        self.torch = torch
        self.input = torch.zeros((1, channels, INPUT_SIZE[1], INPUT_SIZE[0]), device=device)
        cache = Path(cache_dir)
        cache.mkdir(parents=True, exist_ok=True)
        model_path = cache / "latest.onnx"

        class Latest(torch.nn.Module):
            def __init__(self, network):
                super().__init__()
                self.network = network

            def forward(self, value):
                return self.network(value)[:, -1:]

        # Per-session cache directory is keyed by the source weights by the caller.
        if not model_path.exists():
            with torch.inference_mode(), torch.autocast("cuda"):
                torch.onnx.export(
                    Latest(model).eval(),
                    (self.input,),
                    str(model_path),
                    input_names=["input"],
                    output_names=["heatmaps"],
                    opset_version=17,
                    dynamo=False,
                )
        spec = SimpleNamespace(name="input", shape=list(self.input.shape))
        original = SimpleNamespace(
            onnx_model=str(model_path), session=SimpleNamespace(get_inputs=lambda: [spec])
        )
        self.session, self.assignments = _rtx_session(original, 1, False, cache / "engines")
        self.binding = self.session.io_binding()
        self.binding.bind_input(
            "input", "cuda", 0, np.float32, tuple(self.input.shape), self.input.data_ptr()
        )
        self.binding.bind_output("heatmaps", "cuda")

    def run(self, batch):
        if tuple(batch.shape) != tuple(self.input.shape):
            raise ValueError("unexpected TrackNet input shape")
        self.input.copy_(batch)
        # PyTorch and the ORT plugin can use different streams.
        self.torch.cuda.current_stream(batch.device).synchronize()
        self.session.run_with_iobinding(self.binding)
        return self.binding.copy_outputs_to_cpu()[0][0, 0].astype(np.float32)
