"""Optional per-Watch TensorRT RTX sessions, isolated from shared RTMLib models."""

from __future__ import annotations

import copy
import logging
import threading
from pathlib import Path

log = logging.getLogger(__name__)
_registration_lock = threading.Lock()
_registered = False


class _FallbackSession:
    """Retry a failed experimental inference once on the original CUDA session."""

    def __init__(self, accelerated, fallback, diagnostic):
        self.accelerated, self.fallback, self.diagnostic = accelerated, fallback, diagnostic

    def __getattr__(self, name):
        return getattr(self.accelerated, name)

    def run(self, *args, **kwargs):
        if self.diagnostic["active"] != "tensorrt_rtx":
            return self.fallback.run(*args, **kwargs)
        try:
            return self.accelerated.run(*args, **kwargs)
        except Exception as exc:
            log.exception("TensorRT RTX inference failed; falling back to CUDA")
            self.diagnostic.update(active="cuda", fallback_reason=str(exc))
            return self.fallback.run(*args, **kwargs)


def _rtx_session(original, batch_size, is_pose, cache_dir, opt_batch=4):
    import onnxruntime as ort
    import onnxruntime_ep_nv_tensorrt_rtx as plugin

    global _registered
    with _registration_lock:
        if not _registered:
            if not any(d.ep_name == "NvTensorRTRTXExecutionProvider" for d in ort.get_ep_devices()):
                ort.register_execution_provider_library(
                    plugin.get_ep_name(), plugin.get_library_path()
                )
            _registered = True
    devices = [d for d in ort.get_ep_devices() if d.ep_name == "NvTensorRTRTXExecutionProvider"]
    if not devices:
        raise RuntimeError("TensorRT RTX device is unavailable")
    inputs = original.session.get_inputs()
    if len(inputs) != 1:
        raise ValueError("TensorRT RTX experiment requires a single model input")
    spec = inputs[0]
    shape = list(spec.shape)
    if any(not isinstance(x, int) or x <= 0 for x in shape[1:]):
        raise ValueError(f"unsupported dynamic input shape: {shape}")
    dynamic = not isinstance(shape[0], int) or shape[0] <= 0
    minimum = [1, *shape[1:]] if dynamic else shape
    maximum = [batch_size if is_pose else 1, *shape[1:]] if dynamic else shape
    opt_size = min(batch_size, max(1, opt_batch)) if is_pose else 1
    optimum = [opt_size, *shape[1:]] if dynamic else shape

    def profile(dims):
        return f"{spec.name}:{'x'.join(str(x) for x in dims)}"

    opts = ort.SessionOptions()
    opts.add_session_config_entry("session.record_ep_graph_assignment_info", "1")
    options = {
        "nv_profile_min_shapes": profile(minimum),
        "nv_profile_opt_shapes": profile(optimum),
        "nv_profile_max_shapes": profile(maximum),
    }
    if cache_dir:
        Path(cache_dir).mkdir(parents=True, exist_ok=True)
        options["nv_runtime_cache_path"] = str(Path(cache_dir).resolve())
    opts.add_provider_for_devices(devices, options)
    session = ort.InferenceSession(original.onnx_model, sess_options=opts)
    assignments = [
        {"provider": item.ep_name, "nodes": len(item.get_nodes())}
        for item in session.get_provider_graph_assignment_info()
    ]
    if not any(item["provider"] == "NvTensorRTRTXExecutionProvider" for item in assignments):
        raise RuntimeError("TensorRT RTX was not assigned any model nodes")
    return session, assignments


def make_watch_body(
    body, provider, batch_size, device, cache_dir=None, opt_batch=4, split_detector=False
):
    """Copy model wrappers, retaining their original CUDA sessions as fallbacks."""
    if provider not in ("cuda", "detector", "pose", "both"):
        raise ValueError(f"unknown Watch provider mode: {provider}")
    clone = copy.copy(body)
    diagnostics = {"requested": provider, "models": {}}
    for name, attribute in (("detector", "det_model"), ("pose", "pose_model")):
        original = getattr(body, attribute)
        component = copy.copy(original)
        setattr(clone, attribute, component)
        split = name == "detector" and split_detector
        selected = provider in (name, "both") or split
        requested = "split_tensorrt_rtx" if split else "tensorrt_rtx" if selected else "cuda"
        info = {"requested": requested, "active": "cuda"}
        if hasattr(original.session, "get_providers"):
            info["fallback_providers"] = original.session.get_providers()
        diagnostics["models"][name] = info
        if not selected:
            continue
        try:
            if str(device) not in ("cuda", "cuda:0"):
                raise ValueError("TensorRT RTX experiment currently supports CUDA device 0 only")
            if split:
                from shuttlesense.pose.watch_split_detector import make_split_detector

                accelerated, assignments = make_split_detector(original, cache_dir)
            else:
                accelerated, assignments = _rtx_session(
                    original, batch_size, name == "pose", cache_dir, opt_batch
                )
            info.update(active="tensorrt_rtx", assignments=assignments)
            component.session = _FallbackSession(accelerated, original.session, info)
        except Exception as exc:
            info["fallback_reason"] = str(exc)
            log.exception("Could not initialize TensorRT RTX for %s; using CUDA", name)
    return clone, diagnostics
