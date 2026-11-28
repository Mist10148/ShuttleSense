"""Player detection, near/far assignment and keypoints (F3/F4, FR-3/FR-4).

Default backend: rtmlib (YOLOX + RTMPose, COCO-17). Fallback: torchvision Keypoint R-CNN.
The choice is made in the Phase 1 spike (T1.5) and set in configs/pipeline.yaml.
"""

from __future__ import annotations

import logging
import time
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


def _rtmlib_detector(mode: str, device: str, body=None):
    try:
        from rtmlib import Body  # docs/SETUP.md
    except ImportError as exc:
        raise StageSkipped("rtmlib is not installed") from exc
    from shuttlesense.pose.tracking import bbox_from_keypoints

    if body is None:
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

    def make_lookup(enabled):
        if not enabled:
            return None
        try:
            from shuttlesense.pose.watch_preprocess import PoseCropLookup

            return PoseCropLookup(body.pose_model)
        except Exception:
            log.exception("Pose crop lookup unavailable; using original preprocessing")
            return None

    def with_batch(batch_size: int, use_lookup=False):
        # The body and ONNX sessions are shared, but the batch switch belongs to one
        # Watch session and must not change live or upload inference.
        enabled = True
        lookup = make_lookup(use_lookup)

        def detect_batched(frame: np.ndarray) -> list[Player]:
            nonlocal enabled
            if not enabled:
                return detect(frame)
            try:
                if lookup is not None:
                    return players_from_pose(
                        *_batched_body_pose(body, frame, batch_size, crop_lookup=lookup)
                    )
                return players_from_pose(*_batched_body_pose(body, frame, batch_size))
            except Exception:
                # Unsupported model/runtime or resource pressure: fall back for the
                # rest of this session, preserving the original model's behavior.
                log.exception("Watch pose batching failed; using sequential inference")
                enabled = False
                return detect(frame)

        return detect_batched

    def with_watch(batch_size, candidates, use_lookup=False):
        batched = with_batch(batch_size, use_lookup) if batch_size > 1 else detect
        lookup = make_lookup(use_lookup)
        enabled = True

        def detect_watch(frame):
            nonlocal enabled
            if not enabled:
                candidates.excluded_players = []
                return batched(frame)
            try:
                start = time.perf_counter()
                boxes = body.det_model(frame)
                detected = len(boxes)
                detection_s = time.perf_counter() - start
                # RTMLib falls back to the whole image when YOLO returns no boxes.
                if detected == 0:
                    boxes = [[0, 0, frame.shape[1], frame.shape[0]]]
                start = time.perf_counter()
                keep = candidates.select(boxes, frame.shape)
                selection_s = time.perf_counter() - start
                indices = [
                    i for i, selected in enumerate(keep) if selected or candidates.mode == "shadow"
                ]
                start = time.perf_counter()
                if not indices:
                    candidates.record(
                        detected, keep, detection_s, time.perf_counter() - start, selection_s
                    )
                    return []
                selected_boxes = [boxes[i] for i in indices]
                if batch_size > 1:
                    if lookup is not None:
                        keypoints, scores = _batched_body_pose(
                            body, frame, batch_size, selected_boxes, crop_lookup=lookup
                        )
                    else:
                        keypoints, scores = _batched_body_pose(
                            body, frame, batch_size, selected_boxes
                        )
                else:
                    keypoints, scores = body.pose_model(frame, selected_boxes)
                pose_s = time.perf_counter() - start
                candidates.record(
                    detected, keep if detected else [], detection_s, pose_s, selection_s
                )
                people = players_from_pose(keypoints, scores)
                if getattr(candidates, "proposal", None) is not None:
                    for index, kps, score in zip(indices, keypoints, scores, strict=True):
                        if keep[index] and not candidates.proposal_keep[index]:
                            candidates.proposal_players.extend(players_from_pose([kps], [score]))
                if candidates.mode == "shadow":
                    for index, kps, score in zip(indices, keypoints, scores, strict=True):
                        if not keep[index]:
                            candidates.excluded_players.extend(players_from_pose([kps], [score]))
                return people
            except Exception:
                log.exception("Watch candidate selection failed; using unfiltered inference")
                enabled = False
                candidates.excluded_players = []
                candidates.stats["fallback"] = True
                return batched(frame)

        return detect_watch

    detect.with_batch = with_batch
    detect.with_watch = with_watch

    def with_provider(provider, batch_size, opt_batch=4, split_detector=False):
        from shuttlesense.config import BACKEND_DIR
        from shuttlesense.pose.watch_acceleration import make_watch_body

        cache = BACKEND_DIR / ".cache" / "tensorrt_rtx"
        watch_body, diagnostics = make_watch_body(
            body, provider, batch_size, device, cache, opt_batch, split_detector
        )
        watch_detect = _rtmlib_detector(mode, device, body=watch_body)
        watch_detect.provider_diagnostics = diagnostics
        return watch_detect

    detect.with_provider = with_provider

    return detect


def _batched_body_pose(
    body, frame: np.ndarray, batch_size: int, boxes=None, *, vectorized=False, crop_lookup=None
):
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
    if boxes is None:
        boxes = body.det_model(frame)
    if len(boxes) == 0:
        boxes = [[0, 0, frame.shape[1], frame.shape[0]]]
    keypoints, scores = [], []
    outputs = [output.name for output in session.get_outputs()]
    for start in range(0, len(boxes), max(1, batch_size)):
        selected = boxes[start : start + batch_size]
        batch = None
        if crop_lookup is not None and crop_lookup.enabled:
            try:
                batch, geometry = crop_lookup.prepare(frame, selected)
                prepared = [(None, center, scale) for center, scale in geometry]
            except Exception:
                log.exception("Pose crop lookup failed; using original preprocessing")
                crop_lookup.enabled = False
        if batch is None:
            prepared = [pose.preprocess(frame, b) for b in selected]
            batch = np.stack(
                [
                    np.ascontiguousarray(img.transpose(2, 0, 1), dtype=np.float32)
                    for img, _, _ in prepared
                ]
            )
        result = session.run(outputs, {input_info.name: batch})
        native_pose = (
            vectorized
            and type(pose).__name__ == "RTMPose"
            and type(pose).__module__ == "rtmlib.tools.pose_estimation.rtmpose"
        )
        if native_pose:
            centers = np.asarray([center for _, center, _ in prepared])
            scales = np.asarray([scale for _, _, scale in prepared])
            native_pose = centers.shape == (len(prepared), 2) and scales.shape == centers.shape
        if native_pose:
            # RTMPose's SimCC decoder accepts batched results. Broadcasting each
            # crop's geometry avoids repeating identical NumPy operations per person.
            kps, score = pose.postprocess(result, centers[:, None, :], scales[:, None, :])
            if kps.shape[0] != len(prepared) or score.shape[0] != len(prepared):
                raise ValueError("pose postprocessing returned an unexpected batch size")
            keypoints.append(kps)
            scores.append(score)
        else:
            for index, (_, center, scale) in enumerate(prepared):
                kps, score = pose.postprocess([r[index : index + 1] for r in result], center, scale)
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
    from shuttlesense.pose.doubles_keeper import with_doubles_keeper

    tracker = with_doubles_keeper(tracker, cfg)  # D66: all four doubles players
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
