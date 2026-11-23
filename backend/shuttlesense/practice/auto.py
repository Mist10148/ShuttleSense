"""Automatic stroke candidates for the selected player.

These are estimates; missing shuttle or pose evidence never becomes a confident label.
"""

from __future__ import annotations

import copy
import logging

from shuttlesense import hits, strokes
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext, StageSkipped
from shuttlesense.stream.watch_strokes import guard_hits
from shuttlesense.strokes import registry
from shuttlesense.strokes.classify import load_classifier

log = logging.getLogger(__name__)


def analyze_strokes(
    record: ClipRecord, config: dict, device: str, unobserved: set[int]
) -> list[dict]:
    """Detect hits and classify using the shipped CNN and Watch evidence guard."""
    cfg = copy.deepcopy(config)
    cfg["_unobserved_frames"] = unobserved
    stages = cfg.setdefault("stages", {})
    stroke_cfg = stages.setdefault("strokes", {})
    stroke_cfg["algorithm"] = "cnn"
    # Match/rally priors are not valid assumptions for isolated practice.
    stroke_cfg["context"] = {"enabled": False}
    ctx = StageContext(video_path=None, out_dir=None, config=cfg, device=device)
    hits.run(record, ctx)
    # Practice records only contain the selected player in the near slot.
    record.hits = [h for h in record.hits if h.player == "near" and h.frame not in unobserved]
    if not record.hits:
        return []
    try:
        _, checkpoint = load_classifier(registry.weights_path(stroke_cfg, "cnn"), device)
        strokes.run(record, ctx)
        guard_hits(
            record,
            checkpoint,
            float(cfg.get("watch", {}).get("stroke_min_confidence", 0.5)),
            unobserved=unobserved,
        )
    except (StageSkipped, ImportError, OSError, RuntimeError, ValueError):
        log.warning("Practice CNN unavailable; hit candidates remain unclassified", exc_info=True)
        for hit in record.hits:
            hit.stroke = None
            hit.confidence = None
            hit.class_probs = None
    return [
        {
            "frame": hit.frame,
            "time_s": hit.time_s,
            "stroke": hit.stroke,
            "confidence": hit.confidence,
            "source": "automatic",
            "confirmed": False,
            "model": "cnn" if hit.stroke else None,
        }
        for hit in record.hits
    ]
