"""Player detection, near/far assignment and keypoints (F3/F4, FR-3/FR-4).

Default backend: rtmlib (RTMDet + RTMPose, COCO-17). Fallback: torchvision Keypoint R-CNN.
The choice is made in the Phase 1 spike (T1.5) and set in configs/pipeline.yaml.
"""

from __future__ import annotations

from shuttlesense.schema import ClipRecord, Player
from shuttlesense.stage import StageContext


def assign_sides(players: list[Player]) -> tuple[Player | None, Player | None]:
    """Split detections into (near, far): near is the one whose feet are lower in the image.

    TODO(T2.4): once the court is calibrated, assign by court side instead and keep IDs
    stable across frames (nearest previous bbox).
    """
    if not players:
        return None, None
    ordered = sorted(players, key=lambda p: p.bbox[1] + p.bbox[3], reverse=True)
    near = ordered[0]
    far = ordered[1] if len(ordered) > 1 else None
    return near, far


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill frames[].players.

    TODO(T2.4): detect people per frame (lazy rtmlib import), keep the two on court.
    TODO(T2.5): keypoints per player with light temporal smoothing.
    """
    ctx.progress(1.0)
    return record
