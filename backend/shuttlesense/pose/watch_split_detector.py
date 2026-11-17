"""Experimental YOLOX split around TensorRT RTX's unsupported TopK."""

from __future__ import annotations

import hashlib
from pathlib import Path
from types import SimpleNamespace

import numpy as np

BOUNDARY = ("1436", "1438", "1443")


class SplitDetectorSession:
    """Keep split activations on GPU; use a stable host input and CUDA postprocessing."""

    def __init__(self, original, front, post):
        self.original, self.front, self.post = original, front, post
        spec = original.get_inputs()[0]
        self.input_name = spec.name
        self.input = np.empty(spec.shape, dtype=np.float32)
        self.binding = front.io_binding()
        self.binding.bind_cpu_input(self.input_name, self.input)
        for name in BOUNDARY:
            self.binding.bind_output(name, "cuda")

    def __getattr__(self, name):
        return getattr(self.original, name)

    def run(self, output_names, inputs, *args, **kwargs):
        if args or kwargs or set(inputs) != {self.input_name}:
            raise ValueError("unsupported split detector inference arguments")
        np.copyto(self.input, inputs[self.input_name], casting="no")
        self.binding.bind_cpu_input(self.input_name, self.input)
        self.binding.synchronize_inputs()
        self.front.run_with_iobinding(self.binding)
        self.binding.synchronize_outputs()
        binding = self.post.io_binding()
        values = self.binding.get_outputs()
        for name, value in zip(BOUNDARY, values, strict=True):
            binding.bind_ortvalue_input(name, value)
        names = output_names or [out.name for out in self.original.get_outputs()]
        for name in names:
            binding.bind_output(name, "cpu")
        self.post.run_with_iobinding(binding)
        return binding.copy_outputs_to_cpu()


def make_split_detector(component, cache_dir):
    """Build the known YOLOX graph only; unsupported versions fall back to CUDA."""
    import onnx
    import onnxruntime as ort

    from shuttlesense.pose.watch_acceleration import _rtx_session

    source = Path(component.onnx_model)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()[:16]
    cache = Path(cache_dir) / "detector_split" / digest
    cache.mkdir(parents=True, exist_ok=True)
    front_path, post_path = cache / "front.onnx", cache / "post.onnx"
    if not front_path.is_file() or not post_path.is_file():
        graph = onnx.shape_inference.infer_shapes(onnx.load(source))
        available = {value.name for value in graph.graph.value_info}
        if not set(BOUNDARY).issubset(available):
            raise ValueError("unsupported YOLOX graph: split boundaries missing")
        extractor = onnx.utils.Extractor(graph)
        front = extractor.extract_model([graph.graph.input[0].name], list(BOUNDARY))
        post = extractor.extract_model(list(BOUNDARY), [x.name for x in graph.graph.output])
        onnx.checker.check_model(front)
        onnx.checker.check_model(post)
        onnx.save(front, front_path)
        onnx.save(post, post_path)
    model = SimpleNamespace(session=component.session, onnx_model=str(front_path))
    front, assignments = _rtx_session(model, 1, False, cache / "engines")
    post = ort.InferenceSession(
        str(post_path), providers=["CUDAExecutionProvider", "CPUExecutionProvider"]
    )
    if "CUDAExecutionProvider" not in post.get_providers():
        raise RuntimeError("CUDA postprocessing provider is unavailable")
    return SplitDetectorSession(component.session, front, post), assignments
