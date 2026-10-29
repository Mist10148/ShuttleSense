"""TrackNetV3 wrapper (F2, FR-2).

The TrackNetV3 code lives in backend/third_party/TrackNetV3 (git submodule, task T1.3)
and its weights in backend/weights/tracknet/ (task T1.4).
"""

from __future__ import annotations

from shuttlesense.schema import ClipRecord
from shuttlesense.stage import StageContext


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill frames[].shuttle with (x, y, visible) per frame.

    TODO(T2.2): load TrackNet + InpaintNet on ctx.device (lazy torch import), run over
    normalized frames in sliding windows, write tracking.csv to ctx.out_dir.
    TODO(T2.3): rectify with InpaintNet, then fill short gaps with interpolate_gaps().
    """
    ctx.progress(1.0)
    return record
