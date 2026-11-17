"""Stroke inference stage (F6, FR-6): 1D CNN, LSTM, Random Forest (D28), or all three (D37)."""

from __future__ import annotations

from typing import Any

import numpy as np

from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import STROKE_CLASSES, ClipRecord
from shuttlesense.stage import StageContext, StageSkipped
from shuttlesense.strokes import context, registry
from shuttlesense.strokes.features import POSE_FEATURES, build_window

_MODELS: dict[tuple[str, str, int, int], Any] = {}


def load_classifier(path: str, device: str):
    """(model, checkpoint dict), cached per (path, device) so the API worker loads it once.

    The checkpoint dict says what the file holds: "kind" is "cnn" (also when missing),
    "lstm" or "rf". An .npz file is a Random Forest (strokes/rf.py); anything else is a torch
    checkpoint. The key also holds the file's size and mtime: replacing the weights while the
    server runs loads the new ones (the stage cache already notices the change, see cache.py).
    """
    weights = BACKEND_DIR / path
    if not weights.exists():
        raise StageSkipped("stroke model not installed")
    stat = weights.stat()
    key = (path, device, stat.st_size, stat.st_mtime_ns)
    if key in _MODELS:
        return _MODELS[key]
    if weights.suffix == ".npz":
        from shuttlesense.strokes.rf import Forest

        forest = Forest.load(weights)
        _MODELS[key] = (forest, {**forest.meta, "kind": "rf"})
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
    kind = ckpt.get("kind", "cnn")
    model = build_from_config(ckpt["in_features"], model_cfg, len(classes), kind)
    model.load_state_dict(ckpt["state_dict"])
    model.to(device).eval()
    _MODELS[key] = (model, ckpt)
    return _MODELS[key]


def pose_slots(record: ClipRecord, hits_cfg: dict[str, Any]) -> list[str]:
    """The Players field whose pose each hit's window is built from.

    Singles: the side. Doubles: the credited partner; when the two partners' wrists were too
    close to credit one (Hit.hitter is None), the closer of the two is still the better
    guess than always the first partner, so the window follows that one. The hit itself
    stays uncredited.
    """
    from shuttlesense.hits.detector import closest_partner
    from shuttlesense.schema import is_doubles

    if not is_doubles(record):
        return [h.player_attr for h in record.hits]
    cfg = dict(hits_cfg)
    cfg["scale"] = (record.height or 720) / 720
    return [
        h.player_attr if h.hitter else closest_partner(record, h, cfg) or h.player_attr
        for h in record.hits
    ]


def softmax(logits: np.ndarray) -> np.ndarray:
    z = logits - logits.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def predict_proba(
    model: Any, kind: str, x: np.ndarray, device: str, temperature: float = 1.0
) -> np.ndarray:
    """[N, classes] probabilities for windows x [N, T, F] from any of the three models.

    `temperature` divides the logits of a network before the softmax (1.0 leaves them as
    they are). Training fits it on the validation split and stores it in the checkpoint, so
    `confidence` is closer to how often the model is right; the predicted class is unchanged.
    """
    if kind == "rf":
        from shuttlesense.strokes.rf import summary_features

        return model.predict_proba(summary_features(x, model.meta.get("summary_version", 1)))
    import torch

    batch = x if kind == "lstm" else np.transpose(x, (0, 2, 1))
    with torch.inference_mode():
        logits = model(torch.from_numpy(np.ascontiguousarray(batch)).to(device))
    return softmax(logits.float().cpu().numpy() / max(float(temperature), 1e-3))


def average_probabilities(
    parts: list[tuple[np.ndarray, list[str]]], classes: list[str]
) -> np.ndarray:
    """Mean of several models' [N, classes] probabilities, each given with its class order.

    The models' confidences are already calibrated (temperature for the networks, leaf
    frequencies for the forest), so a plain mean lets a confident model outvote two unsure
    ones. A class a model does not know counts as 0 for it.
    """
    total = np.zeros((len(parts[0][0]), len(classes)), dtype=np.float64)
    for probs, order in parts:
        for j, c in enumerate(order):
            if c in classes:
                total[:, classes.index(c)] += probs[:, j]
    total /= len(parts)
    return total / np.maximum(total.sum(axis=1, keepdims=True), 1e-12)


def model_probabilities(
    record: ClipRecord, ctx: StageContext, name: str, slots: list[str]
) -> tuple[np.ndarray, list[str]]:
    """([hits, classes] probabilities, class order) of one trained model for record.hits."""
    cfg = ctx.stage_config("strokes")
    try:
        model, ckpt = load_classifier(registry.weights_path(cfg, name), ctx.device)
    except StageSkipped as exc:
        if name == registry.DEFAULT_ALGORITHM:
            raise
        raise StageSkipped(f"{exc} ({registry.LABELS[name]})") from exc
    # The model was trained on a fixed window and feature layout: take both from the checkpoint.
    window = int(ckpt.get("window_frames", cfg.get("window_frames", 32)))
    if "use_trajectory" in ckpt:
        use_traj = bool(ckpt["use_trajectory"])
    elif "in_features" in ckpt:
        use_traj = int(ckpt["in_features"]) > POSE_FEATURES
    else:
        use_traj = cfg.get("use_trajectory", True)
    pose_norm = ckpt.get("pose_norm", "bbox_height")
    classes = ckpt.get("classes", list(STROKE_CLASSES))
    # Optional keys of newer checkpoints; without them the window is the clip's own frames
    # and the confidence is the plain softmax, as for the first weights.
    window_fps = ckpt.get("window_fps")
    x = np.stack(
        [
            build_window(record, h.frame, slot, window, use_traj, pose_norm, window_fps)
            for h, slot in zip(record.hits, slots, strict=True)
        ]
    )
    temperature = float(ckpt.get("temperature", 1.0))
    return predict_proba(model, ckpt.get("kind", "cnn"), x, ctx.device, temperature), classes


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill hits[].stroke (argmax), confidence and class_probs; note the model used."""
    if not record.hits:
        raise StageSkipped("no hits to classify")
    name = registry.algorithm(ctx.stage_config("strokes"))
    if name not in registry.ALGORITHMS:
        raise StageSkipped(f"stroke model {name!r} is not implemented")
    slots = pose_slots(record, ctx.stage_config("hits"))
    parts = [model_probabilities(record, ctx, m, slots) for m in registry.members(name)]
    probs, classes = parts[0]
    if len(parts) > 1:
        classes = list(STROKE_CLASSES)
        probs = average_probabilities(parts, classes)
    for hit, p in zip(record.hits, probs, strict=True):
        best = int(p.argmax())
        hit.stroke = classes[best]
        hit.confidence = round(float(p[best]), 4)
        hit.class_probs = {c: round(float(v), 4) for c, v in zip(classes, p, strict=True)}
    # Where the hit sits in the rally and on the court, on top of whichever model ran.
    context.refine(record, ctx.config)
    record.stroke_model = name
    ctx.progress(1.0)
    return record
