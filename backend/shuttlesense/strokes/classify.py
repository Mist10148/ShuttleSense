"""Stroke inference stage (F6, FR-6)."""

from __future__ import annotations

from typing import Any

import numpy as np

from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import STROKE_CLASSES, ClipRecord
from shuttlesense.stage import StageContext, StageSkipped
from shuttlesense.strokes.features import POSE_FEATURES, build_window

_MODELS: dict[tuple[str, str, int, int], Any] = {}


def load_classifier(path: str, device: str):
    """(model, checkpoint dict), cached per (path, device) so the API worker loads it once.

    The key also holds the file's size and mtime: replacing the weights while the server
    runs loads the new ones (the stage cache already notices the change, see cache.py).
    """
    weights = BACKEND_DIR / path
    if not weights.exists():
        raise StageSkipped("stroke model not installed")
    stat = weights.stat()
    key = (path, device, stat.st_size, stat.st_mtime_ns)
    if key in _MODELS:
        return _MODELS[key]
    try:
        import torch
    except ImportError as exc:
        raise StageSkipped("torch is not installed") from exc
    from shuttlesense.strokes.model import build_from_config

    # The checkpoint holds only tensors and plain containers, so no pickled code may run.
    ckpt = torch.load(weights, map_location=device, weights_only=True)
    classes = ckpt.get("classes", list(STROKE_CLASSES))
    model_cfg = ckpt.get("config", {}).get("model", {})
    model = build_from_config(ckpt["in_features"], model_cfg, len(classes))
    model.load_state_dict(ckpt["state_dict"])
    model.to(device).eval()
    _MODELS[key] = (model, ckpt)
    return _MODELS[key]


def softmax(logits: np.ndarray) -> np.ndarray:
    z = logits - logits.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill hits[].stroke (argmax), confidence and class_probs."""
    if not record.hits:
        raise StageSkipped("no hits to classify")
    cfg = ctx.stage_config("strokes")
    model, ckpt = load_classifier(cfg.get("weights", "weights/strokes/stroke_cnn.pt"), ctx.device)
    # The model was trained on a fixed window and feature layout: take both from the checkpoint.
    window = int(ckpt.get("window_frames", cfg.get("window_frames", 32)))
    if "use_trajectory" in ckpt:
        use_traj = bool(ckpt["use_trajectory"])
    elif "in_features" in ckpt:
        use_traj = int(ckpt["in_features"]) > POSE_FEATURES
    else:
        use_traj = cfg.get("use_trajectory", True)
    classes = ckpt.get("classes", list(STROKE_CLASSES))
    x = np.stack([build_window(record, h.frame, h.player, window, use_traj) for h in record.hits])

    import torch

    with torch.inference_mode():
        logits = model(torch.from_numpy(np.transpose(x, (0, 2, 1)).copy()).to(ctx.device))
    probs = softmax(logits.float().cpu().numpy())
    for hit, p in zip(record.hits, probs, strict=True):
        best = int(p.argmax())
        hit.stroke = classes[best]
        hit.confidence = round(float(p[best]), 4)
        hit.class_probs = {c: round(float(v), 4) for c, v in zip(classes, p, strict=True)}
    ctx.progress(1.0)
    return record
