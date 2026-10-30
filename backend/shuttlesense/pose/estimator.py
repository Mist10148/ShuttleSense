"""Player detection, near/far assignment and keypoints (F3/F4, FR-3/FR-4).

Default backend: rtmlib (RTMDet + RTMPose, COCO-17). Fallback: torchvision Keypoint R-CNN.
The choice is made in the Phase 1 spike (T1.5) and set in configs/pipeline.yaml.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from shuttlesense.schema import COURT_SIZE_M, ClipRecord, Player
from shuttlesense.stage import StageContext, StageSkipped

_MODELS: dict[tuple[str, str, str], Any] = {}


def assign_sides(players: list[Player]) -> tuple[Player | None, Player | None]:
    """Split detections into (near, far): near is the one whose feet are lower in the image.

    Used on the first frame only; PlayerTracker keeps the IDs stable afterwards.
    """
    if not players:
        return None, None
    ordered = sorted(players, key=lambda p: p.bbox[1] + p.bbox[3], reverse=True)
    near = ordered[0]
    far = ordered[1] if len(ordered) > 1 else None
    return near, far


def load_detector(backend: str, mode: str, device: str):
    """Callable frame -> list[Player], cached per (backend, mode, device) across jobs."""
    key = (backend, mode, device)
    if key in _MODELS:
        return _MODELS[key]
    if backend != "rtmlib":
        # TODO(T1.5): torchvision Keypoint R-CNN fallback if the spike picks it.
        raise StageSkipped(f"pose backend {backend!r} is not implemented")
    try:
        from rtmlib import Body  # requirements/ml.txt
    except ImportError as exc:
        raise StageSkipped("rtmlib is not installed") from exc
    from shuttlesense.pose.tracking import bbox_from_keypoints

    body = Body(mode=mode, backend="onnxruntime", device=device)

    def detect(frame: np.ndarray) -> list[Player]:
        keypoints, scores = body(frame)  # (N, 17, 2), (N, 17)
        people = []
        for kps, sc in zip(keypoints, scores, strict=False):
            bbox = bbox_from_keypoints(kps, sc)
            if bbox is None:
                continue
            people.append(
                Player(
                    bbox=bbox,
                    keypoints=[
                        (float(x), float(y), float(s)) for (x, y), s in zip(kps, sc, strict=False)
                    ],
                    score=float(np.mean(sc)),
                )
            )
        return people

    _MODELS[key] = detect
    return detect


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill frames[].players with near/far boxes and smoothed COCO-17 keypoints."""
    from shuttlesense.pose.tracking import PlayerTracker, filter_players, smooth_keypoints

    if ctx.reader is None:
        raise StageSkipped("no frames (io stage did not run)")
    cfg = ctx.stage_config("pose")
    detect = load_detector(cfg.get("backend", "rtmlib"), cfg.get("mode", "balanced"), ctx.device)
    homography = None
    court_size = tuple(ctx.stage_config("court").get("court_size_m", COURT_SIZE_M))
    if ctx.config.get("court_corners_px"):
        from shuttlesense.court import compute_homography

        corners = ctx.config["court_corners_px"]
        if ctx.reader.resized:
            sx = ctx.reader.width / ctx.reader.source.width
            sy = ctx.reader.height / ctx.reader.source.height
            corners = [[x * sx, y * sy] for x, y in corners]
        homography = compute_homography(corners, court_size)

    tracker = PlayerTracker(hold_frames=cfg.get("hold_frames", 5))
    min_score = cfg.get("min_person_score", 0.4)
    total = max(len(ctx.reader), 1)
    for i, frame in ctx.reader:
        people = [p for p in detect(frame) if p.score >= min_score]
        people = filter_players(
            people, frame_height=record.height, homography=homography, court_size=court_size
        )
        near, far = tracker.update(people)
        record.frames[i].players.near = near
        record.frames[i].players.far = far
        if i % 25 == 0:
            ctx.progress(i / total)

    window = cfg.get("smoothing_window", 5)
    min_kp = cfg.get("min_keypoint_score", 0.3)
    for side in ("near", "far"):
        players = [getattr(f.players, side) for f in record.frames]
        smoothed = smooth_keypoints(
            [p.keypoints if p else None for p in players], window=window, min_score=min_kp
        )
        for p, kps in zip(players, smoothed, strict=True):
            if p is not None and kps is not None:
                p.keypoints = kps
    ctx.progress(1.0)
    return record
