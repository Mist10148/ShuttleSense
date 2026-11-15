"""Player detection, near/far assignment and keypoints (F3/F4, FR-3/FR-4).

Default backend: rtmlib (YOLOX + RTMPose, COCO-17). Fallback: torchvision Keypoint R-CNN.
The choice is made in the Phase 1 spike (T1.5) and set in configs/pipeline.yaml.
"""

from __future__ import annotations

import logging
from typing import Any

import numpy as np

from shuttlesense.schema import COURT_SIZE_M, ClipRecord, Player
from shuttlesense.stage import StageContext, StageSkipped

_MODELS: dict[tuple[str, str, str], Any] = {}
log = logging.getLogger(__name__)


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
    if backend == "rtmlib":
        detect = _rtmlib_detector(mode, device)
    elif backend == "keypoint_rcnn":
        detect = _keypoint_rcnn_detector(device)
    else:
        raise StageSkipped(f"pose backend {backend!r} is not implemented")
    _MODELS[key] = detect
    return detect


def _rtmlib_detector(mode: str, device: str):
    try:
        from rtmlib import Body  # docs/SETUP.md
    except ImportError as exc:
        raise StageSkipped("rtmlib is not installed") from exc
    from shuttlesense.pose.tracking import bbox_from_keypoints

    body = Body(mode=mode, backend="onnxruntime", device=device)

    def players_from_pose(keypoints, scores) -> list[Player]:
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

    def detect(frame: np.ndarray) -> list[Player]:
        return players_from_pose(*body(frame))

    def with_batch(batch_size: int):
        # The body and ONNX sessions are shared, but the batch switch belongs to one
        # Watch session and must not change live or upload inference.
        enabled = True

        def detect_batched(frame: np.ndarray) -> list[Player]:
            nonlocal enabled
            if not enabled:
                return detect(frame)
            try:
                return players_from_pose(*_batched_body_pose(body, frame, batch_size))
            except Exception:
                # Unsupported model/runtime or resource pressure: fall back for the
                # rest of this session, preserving the original model's behavior.
                log.exception("Watch pose batching failed; using sequential inference")
                enabled = False
                return detect(frame)

        return detect_batched

    detect.with_batch = with_batch

    return detect



def _batched_body_pose(body, frame: np.ndarray, batch_size: int):
    """RTMLib's normal detection and pose preprocessing, grouped per frame."""
    if body.one_stage or body.pose_model.backend != "onnxruntime":
        raise ValueError("batching requires a two-stage ONNX RTMPose model")
    pose = body.pose_model
    if pose.to_openpose:
        raise ValueError("batching expects COCO keypoints")
    session = pose.session
    input_info = session.get_inputs()[0]
    if isinstance(input_info.shape[0], int) and input_info.shape[0] == 1:
        raise ValueError("pose model does not support dynamic batches")
    boxes = body.det_model(frame)
    if len(boxes) == 0:
        boxes = [[0, 0, frame.shape[1], frame.shape[0]]]
    keypoints, scores = [], []
    outputs = [output.name for output in session.get_outputs()]
    for start in range(0, len(boxes), max(1, batch_size)):
        prepared = [pose.preprocess(frame, b) for b in boxes[start:start + batch_size]]
        batch = np.stack([
            np.ascontiguousarray(img.transpose(2, 0, 1), dtype=np.float32)
            for img, _, _ in prepared
        ])
        result = session.run(outputs, {input_info.name: batch})
        for index, (_, center, scale) in enumerate(prepared):
            kps, score = pose.postprocess([r[index:index + 1] for r in result], center, scale)
            keypoints.append(kps)
            scores.append(score)
    return np.concatenate(keypoints, axis=0), np.concatenate(scores, axis=0)


def _keypoint_rcnn_detector(device: str):
    """torchvision Keypoint R-CNN (COCO-17, same joint order as rtmlib). The weights are
    downloaded to the torch hub cache on first use."""
    try:
        import torch
        from torchvision.models.detection import (  # docs/SETUP.md
            KeypointRCNN_ResNet50_FPN_Weights,
            keypointrcnn_resnet50_fpn,
        )
    except ImportError as exc:
        raise StageSkipped("torchvision is not installed") from exc

    weights = KeypointRCNN_ResNet50_FPN_Weights.DEFAULT
    model = keypointrcnn_resnet50_fpn(weights=weights).to(device).eval()

    def detect(frame: np.ndarray) -> list[Player]:
        rgb = np.ascontiguousarray(frame[:, :, ::-1])  # OpenCV frames are BGR
        image = torch.from_numpy(rgb).to(device).permute(2, 0, 1).float() / 255.0
        with torch.inference_mode():
            out = model([image])[0]
        boxes = out["boxes"].cpu().numpy()
        scores = out["scores"].cpu().numpy()
        keypoints = out["keypoints"].cpu().numpy()  # (N, 17, 3): x, y, visibility flag
        # Joint scores are heatmap logits; the sigmoid maps them to 0-1 like rtmlib's.
        joint_scores = torch.sigmoid(out["keypoints_scores"]).cpu().numpy()
        people = []
        for (x0, y0, x1, y1), score, kps, sc in zip(
            boxes, scores, keypoints, joint_scores, strict=True
        ):
            people.append(
                Player(
                    bbox=(float(x0), float(y0), float(x1 - x0), float(y1 - y0)),
                    keypoints=[
                        (float(x), float(y), float(s))
                        for (x, y, _v), s in zip(kps, sc, strict=True)
                    ],
                    score=float(score),
                )
            )
        return people

    return detect


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill frames[].players with near/far boxes and smoothed COCO-17 keypoints."""
    from shuttlesense.config import court_type
    from shuttlesense.pose.far_refinement import FarPlayerRefiner
    from shuttlesense.pose.player_tracker import CourtPlayerTracker
    from shuttlesense.pose.tracking import smooth_keypoints

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

    court = court_type(ctx.config)
    tracker = CourtPlayerTracker(cfg, court, court_size)
    far_refiner = FarPlayerRefiner(cfg, court, court_size)
    min_score = cfg.get("min_person_score", 0.4)
    total = max(len(ctx.reader), 1)
    for i, frame in ctx.reader:
        people = [p for p in detect(frame) if p.score >= min_score]
        people = far_refiner.refine(frame, detect, tracker, people, homography=homography)
        record.frames[i].players = tracker.update(
            people, frame_height=record.height, homography=homography, frame=frame
        )
        record.frames[i].player_hold_safe = tracker.view_valid
        if i % 25 == 0:
            ctx.progress(i / total)

    window = cfg.get("smoothing_window", 5)
    min_kp = cfg.get("min_keypoint_score", 0.3)
    for side in ("near", "far", "near_2", "far_2"):
        players = [getattr(f.players, side) for f in record.frames]
        smoothed = smooth_keypoints(
            [p.keypoints if p else None for p in players], window=window, min_score=min_kp
        )
        for p, kps in zip(players, smoothed, strict=True):
            if p is not None and kps is not None:
                p.keypoints = kps
    ctx.progress(1.0)
    return record
