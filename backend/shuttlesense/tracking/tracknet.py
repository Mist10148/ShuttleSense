"""TrackNetV3 wrapper (F2, FR-2).

The TrackNetV3 code lives in backend/third_party/TrackNetV3 (git submodule, task T1.3)
and its weights in backend/weights/tracknet/ (task T1.4).
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from shuttlesense.config import BACKEND_DIR
from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext, StageSkipped
from shuttlesense.tracking.postprocess import (
    apply_track,
    read_tracking_csv,
    rectify,
    write_tracking_csv,
)

TRACKNET_DIR = BACKEND_DIR / "third_party" / "TrackNetV3"


def predict(ctx: StageContext, weights: Path) -> tuple[np.ndarray, np.ndarray]:
    """Raw TrackNetV3 (x, y, visible) per normalized frame, in normalized video pixels.

    TODO(T2.2): add TRACKNET_DIR to sys.path (lazy torch import), build TrackNet (+ InpaintNet
    when stages.tracking.use_inpaintnet) as upstream predict.py does, cache the models per
    device, run sliding windows over ctx.reader.batch(...) resized to the network input,
    convert each heatmap with postprocess.heatmap_to_xy() and scale back with
    postprocess.scale_to_video(). Call ctx.progress() every batch.
    """
    raise StageSkipped("TrackNetV3 inference is not wired yet (T2.2)")


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill frames[].shuttle with (x, y, visible) per frame and write tracking.csv.

    Sources, in order: a precomputed upstream CSV (`stages.tracking.precomputed_csv`, handy
    for running TrackNetV3's predict.py separately, e.g. on Colab), else the model itself.
    The CSV is in source frames and pixels (predict.py run on the original video) unless
    `stages.tracking.precomputed_space` is "normalized" (e.g. a tracking.csv from this
    pipeline).
    Either way the trajectory is cleaned with outlier removal and short-gap interpolation.
    """
    cfg = ctx.stage_config("tracking")
    n = len(record.frames)
    precomputed = cfg.get("precomputed_csv")
    if precomputed:
        path = BACKEND_DIR / precomputed  # absolute paths stay absolute
        if not path.exists():
            raise FileNotFoundError(f"precomputed tracking CSV not found: {path}")
        step, scale = 1, (1.0, 1.0)
        reader = ctx.reader
        if reader is not None and cfg.get("precomputed_space", "source") == "source":
            step = reader.step
            scale = (reader.width / reader.source.width, reader.height / reader.source.height)
        xy, visible = read_tracking_csv(path, n, step=step, scale=scale)
    else:
        try:
            import torch  # noqa: F401  (requirements/ml.txt)
        except ImportError as exc:
            raise StageSkipped("torch is not installed") from exc
        weights = BACKEND_DIR / cfg.get("tracknet_weights", "weights/tracknet/TrackNet_best.pt")
        if not weights.exists():
            raise StageSkipped(f"missing weights: {weights.name}")
        xy, visible = predict(ctx, weights)

    xy, visible, source = rectify(
        xy,
        visible,
        max_gap=cfg.get("max_gap_frames", 8),
        outlier_px=cfg.get("outlier_px", 80),
    )
    apply_track(record, xy, visible)
    write_tracking_csv(ctx.out_dir / "tracking.csv", xy, visible, source)
    ctx.progress(1.0)
    return record
