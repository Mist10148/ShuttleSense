"""Per-frame perception for live sessions: shuttle and players for the newest frame.

ModelPerception runs the same models and helpers as the offline tracking and pose stages,
frame by frame: TrackNetV3 over a sliding window of its last seq_len frames (so a frame's
shuttle is known as soon as it arrives), and the pose detector plus the near/far tracker.
Live-only differences, all documented in docs/ARCHITECTURE.md: the background median comes
from the first frames instead of the whole clip, InpaintNet and centred smoothing are off
(they need future frames), and outliers are not removed.
"""

from __future__ import annotations

import logging
from collections import deque
from collections.abc import Sequence
from typing import Any, Protocol

import numpy as np

from shuttlesense.schema import ClipRecord, Player, Players, Shuttle

log = logging.getLogger(__name__)


class Perception(Protocol):
    """Shuttle and players for one frame, in the session's full frame pixels.

    The session may pass a downscaled frame when it degrades; the result is still in
    full-size coordinates, so trackers and court mapping never see two scales.
    """

    available: dict[str, bool]

    def __call__(self, frame: np.ndarray, index: int) -> tuple[Shuttle, Players]: ...


def _scale_person(p: Player, sx: float, sy: float) -> Player:
    """Map a detection from its input dimensions to session pixels."""
    x, y, w, h = p.bbox
    return Player(
        bbox=(x * sx, y * sy, w * sx, h * sy),
        keypoints=[(kx * sx, ky * sy, ks) for kx, ky, ks in p.keypoints],
        score=p.score,
    )


def configure_watch_pose(detector, watch, device, batch_size):
    """Apply Watch's pose provider and crop batching independently of court geometry."""
    provider = watch.get("player_provider", "cuda")
    provider_factory = getattr(detector, "with_provider", None)
    split_detector = bool(watch.get("split_detector", False))
    diagnostics = None
    if provider == "cuda" and detector is not None:
        active = "cuda" if str(device).startswith("cuda") else "cpu"
        diagnostics = {
            "requested": provider,
            "models": {
                name: {"requested": active, "active": active} for name in ("detector", "pose")
            },
        }
    if (provider != "cuda" or split_detector) and provider_factory is not None:
        detector = provider_factory(
            provider, batch_size, int(watch.get("pose_opt_batch", 4)), split_detector
        )
        diagnostics = detector.provider_diagnostics
    raw = detector
    batch_factory = getattr(raw, "with_batch", None)
    if batch_size > 1 and batch_factory is not None:
        detector = (
            batch_factory(batch_size, True)
            if watch.get("pose_crop_lookup")
            else batch_factory(batch_size)
        )
    return detector, raw, diagnostics


def enable_watch_player_continuity(perception: Perception) -> None:
    """Enable Watch-only outside-court tracking when model-based pose is available."""
    tracker = getattr(perception, "tracker", None)
    if tracker is not None:
        tracker.watch_outside_tracking = True
    if isinstance(perception, ModelPerception):
        perception.watch_preprocess_cache = True
        configured = (getattr(perception, "config", {}).get("watch") or {}).get(
            "pose_batch_size", 1
        )
        batch_size = max(1, min(16, int(configured)))
        watch = getattr(perception, "config", {}).get("watch") or {}
        track_rtx = watch.get("track_provider", "pytorch") == "rtx"
        if (
            (watch.get("track_gpu_window", False) or track_rtx)
            and perception.model is not None
            and str(perception.device).startswith("cuda")
            and perception.bg_mode == "concat"
        ):
            try:
                from shuttlesense.tracking.watch_gpu_window import WatchGpuWindow

                perception.track_gpu_window = WatchGpuWindow(perception.seq_len, perception.device)
            except Exception:
                log.exception("Could not initialize GPU shuttle window; using CPU input")
        if track_rtx:
            perception.track_provider_diagnostics = {"requested": "rtx", "active": "pytorch"}
            try:
                import hashlib

                import torch

                from shuttlesense.config import BACKEND_DIR
                from shuttlesense.tracking.watch_tracknet_rtx import TrackNetRtx

                if getattr(perception, "track_gpu_window", None) is None:
                    raise RuntimeError("TrackNet RTX requires a CUDA concat input window")
                cfg = perception.config.get("stages", {}).get("tracking", {})
                weights = BACKEND_DIR / cfg.get(
                    "tracknet_weights", "weights/tracknet/TrackNet_best.pt"
                )
                digest = hashlib.sha256(weights.read_bytes()).hexdigest()[:20]
                cache = (
                    BACKEND_DIR / ".cache" / "watch_tracknet_rtx" / f"{digest}-{torch.__version__}"
                )
                channels = perception.model.down_block_1.conv_1.conv.in_channels
                perception.track_rtx = TrackNetRtx(
                    perception.model, channels, perception.device, cache
                )
                perception.track_provider_diagnostics.update(
                    active="rtx", assignments=perception.track_rtx.assignments
                )
            except Exception as exc:
                log.exception("TrackNet TensorRT initialization failed; using PyTorch")
                perception.track_provider_diagnostics["fallback_reason"] = str(exc)
                if not watch.get("track_gpu_window", False):
                    perception.track_gpu_window = None
        perception.detect, raw_detect, diagnostics = configure_watch_pose(
            perception.detect, watch, perception.device, batch_size
        )
        if diagnostics is not None:
            perception.provider_diagnostics = diagnostics
        use_lookup = bool(watch.get("pose_crop_lookup", False))
        mode = watch.get("candidate_filter", "off")
        watch_factory = getattr(raw_detect, "with_watch", None)
        if mode in ("shadow", "filter") and watch_factory and tracker is not None:
            from shuttlesense.pose.watch_candidates import WatchCandidates

            perception.watch_candidates = WatchCandidates(
                tracker,
                perception.homography,
                perception.size,
                mode,
                float(watch.get("candidate_margin_m", 2.0)),
                watch.get("candidate_shadow_margin_m"),
                bool(watch.get("candidate_shadow_footpoint", False)),
                candidates_per_player=watch.get("candidates_per_player", 0),
                refresh_frames=watch.get("candidate_refresh_frames", 5),
            )
            perception.watch_detect = (
                watch_factory(batch_size, perception.watch_candidates, True)
                if use_lookup
                else watch_factory(batch_size, perception.watch_candidates)
            )


class ModelPerception:
    """TrackNetV3 + pose on live frames; a part whose weights or packages are missing is off."""

    court = "singles"  # set from the session config when pose loads

    def __init__(
        self,
        config: dict[str, Any],
        device: str,
        frame_size: tuple[int, int],
        corners_px: Sequence[Sequence[float]] | None,
        background_frames: int = 30,
    ) -> None:
        self.config = config
        self.device = device
        self.size = frame_size
        self.background_frames = background_frames
        self.available = {"tracking": False, "pose": False}
        self.watch_preprocess_cache = False
        stages = config.get("stages", {})
        self._init_tracking(stages.get("tracking", {}))
        self._init_pose(stages.get("pose", {}), stages.get("court", {}), corners_px)

    def _init_tracking(self, cfg: dict[str, Any]) -> None:
        from shuttlesense.config import BACKEND_DIR

        self.model = None
        weights = BACKEND_DIR / cfg.get("tracknet_weights", "weights/tracknet/TrackNet_best.pt")
        try:
            import torch  # noqa: F401
        except ImportError:
            return
        if not weights.exists():
            return
        from shuttlesense.tracking.tracknet import _load_model

        self.model, self.seq_len, self.bg_mode = _load_model(weights, self.device, "tracknet")
        self.window: deque[np.ndarray] = deque(maxlen=self.seq_len)
        self.bg_samples: list[np.ndarray] = []
        self.median: np.ndarray | None = None
        self.available["tracking"] = True

    def _init_pose(
        self, cfg: dict[str, Any], court_cfg: dict[str, Any], corners: Sequence | None
    ) -> None:
        from shuttlesense.config import court_type
        from shuttlesense.pose.estimator import load_detector
        from shuttlesense.pose.far_refinement import FarPlayerRefiner
        from shuttlesense.pose.player_tracker import CourtPlayerTracker
        from shuttlesense.schema import COURT_SIZE_M
        from shuttlesense.stage import StageSkipped

        self.detect = None
        try:
            self.detect = load_detector(
                cfg.get("backend", "rtmlib"), cfg.get("mode", "balanced"), self.device
            )
        except StageSkipped:
            return
        self.min_person_score = cfg.get("min_person_score", 0.4)
        self.court = court_type(self.config)
        self.court_size = tuple(court_cfg.get("court_size_m", COURT_SIZE_M))
        self.tracker = CourtPlayerTracker(cfg, self.court, self.court_size)
        from shuttlesense.pose.doubles_keeper import with_doubles_keeper

        self.tracker = with_doubles_keeper(self.tracker, cfg)  # D66: all four doubles players
        self.far_refiner = FarPlayerRefiner(cfg, self.court, self.court_size)
        self.homography = None
        if corners:
            from shuttlesense.court import compute_homography

            self.homography = compute_homography(corners, self.court_size)
        self.available["pose"] = True

    def __call__(self, frame: np.ndarray, index: int) -> tuple[Shuttle, Players]:
        return self._shuttle(frame), self._players(frame)

    def _shuttle(self, frame: np.ndarray) -> Shuttle:
        if self.model is None:
            return Shuttle()
        import cv2
        import torch

        from shuttlesense.tracking.tracknet import INPUT_SIZE, track_windows

        resized_rgb = (
            cv2.resize(frame[:, :, ::-1], INPUT_SIZE) if self.watch_preprocess_cache else None
        )
        if self.bg_mode and len(self.bg_samples) < self.background_frames:
            self.bg_samples.append(
                resized_rgb
                if resized_rgb is not None
                else cv2.resize(frame, INPUT_SIZE)[:, :, ::-1]
            )
            self.median = np.median(np.stack(self.bg_samples), axis=0).astype(np.uint8)
        if self.watch_preprocess_cache:
            # The window slides by one frame: resize each image once, not once per
            # occurrence in overlapping windows. Keep the dynamic median unchanged.
            self.window.append(resized_rgb)
        else:
            self.window.append(frame)
        frames = list(self.window)
        frames = [frames[0]] * (self.seq_len - len(frames)) + frames  # pad at the start
        gpu_window = getattr(self, "track_gpu_window", None)
        if gpu_window is not None:
            try:
                from shuttlesense.tracking.postprocess import heatmap_to_xy, scale_to_video

                with torch.inference_mode(), torch.autocast("cuda"):
                    batch = gpu_window.push(resized_rgb, self.median)
                    track_rtx = getattr(self, "track_rtx", None)
                    heatmap = (
                        track_rtx.run(batch)
                        if track_rtx is not None
                        else self.model(batch)[:, -1:].float().cpu().numpy()[0, 0]
                    )
                x, y, vis = heatmap_to_xy(heatmap)
                if vis:
                    x, y = scale_to_video(np.array([[x, y]]), INPUT_SIZE, self.size)[0]
                return Shuttle(x=round(x, 1), y=round(y, 1), visible=1) if vis else Shuttle()
            except Exception as exc:
                log.exception("GPU shuttle window failed; using CPU input for this Watch session")
                self.track_gpu_window = None
                self.track_rtx = None
                if getattr(self, "track_provider_diagnostics", None) is not None:
                    self.track_provider_diagnostics.update(
                        active="pytorch", fallback_reason=str(exc)
                    )
        with torch.inference_mode():
            points = track_windows(
                self.model,
                [frames],
                self.bg_mode,
                self.median,
                self.device,
                self.size,
                prepared_rgb=self.watch_preprocess_cache,
                latest_only=self.watch_preprocess_cache,
            )[0]
        x, y, vis = points[-1]
        return Shuttle(x=round(x, 1), y=round(y, 1), visible=1) if vis else Shuttle()

    def _players(self, frame: np.ndarray) -> Players:
        if self.detect is None:
            return Players()
        detector = getattr(self, "watch_detect", self.detect)
        people = [p for p in detector(frame) if p.score >= self.min_person_score]
        sx, sy = self.size[0] / frame.shape[1], self.size[1] / frame.shape[0]
        if abs(sx - 1.0) > 1e-6 or abs(sy - 1.0) > 1e-6:
            people = [_scale_person(p, sx, sy) for p in people]
        refiner = getattr(self, "far_refiner", None)
        if refiner is not None:
            people = refiner.refine(frame, self.detect, self.tracker, people,
                                    homography=self.homography, scale=(sx, sy))  # fmt: skip
        # Boxes are in session pixels; the shirt colours are read from this (smaller) frame.
        result = self.tracker.update(people, frame_height=self.size[1],
                                     homography=self.homography, frame=frame,
                                     image_scale=(1 / sx, 1 / sy))  # fmt: skip
        candidates = getattr(self, "watch_candidates", None)
        if candidates is not None and abs(sx - 1) < 1e-6 and abs(sy - 1) < 1e-6:
            candidates.audit(result)
        return result


class SelectedPracticePerception:
    """Use Watch's court tracker; bind the chosen box to one locked Watch slot."""

    def __init__(self, perception, bbox, selection_frame):
        self.perception = perception
        self.available = perception.available
        self.selected_bbox = tuple(bbox)
        self.selection_frame = selection_frame
        self.selected_slot = None
        self.unobserved = set()
        self.player_hold_safe = False

    def __call__(self, frame, index):
        return self._shuttle(frame), self.players_for_frame(frame, index)

    def _shuttle(self, frame):
        return self.perception._shuttle(frame)

    def players_for_frame(self, frame, index):
        from shuttlesense.practice.evidence import _iou

        players = self.perception._players(frame)
        # Give Watch time to confirm its slot without binding a stale selection later.
        if self.selection_frame <= index <= self.selection_frame + 8 and self.selected_slot is None:
            matches = sorted(
                (
                    (_iou(self.selected_bbox, player.bbox), slot)
                    for slot in ("near", "far", "near_2", "far_2")
                    if (player := getattr(players, slot)) is not None
                ),
                reverse=True,
            )
            if (
                matches
                and matches[0][0] >= 0.35
                and (len(matches) == 1 or matches[0][0] - matches[1][0] >= 0.15)
            ):
                self.selected_slot = matches[0][1]
        selected = (
            getattr(players, self.selected_slot)
            if self.selected_slot is not None and index >= self.selection_frame
            else None
        )
        self.player_hold_safe = selected is not None
        if selected is None:
            self.unobserved.add(index)
        return players

    def close(self):
        close = getattr(self.perception, "close", None)
        if close:
            close()


class ReplayPerception:
    """Shuttle and players read from a record instead of a camera (fake mode, tests).

    The record is scaled to the session's frame size and replayed in a loop.
    """

    # No model runs: the app says the data is synthetic instead of claiming tracking.
    available = {"tracking": False, "pose": False, "synthetic": True}

    def __init__(self, record: ClipRecord, frame_size: tuple[int, int]) -> None:
        self.record = record
        self.sx = frame_size[0] / record.width
        self.sy = frame_size[1] / record.height

    def __call__(self, frame: np.ndarray, index: int) -> tuple[Shuttle, Players]:
        f = self.record.frames[index % len(self.record.frames)]
        s = f.shuttle or Shuttle()
        shuttle = (
            Shuttle(x=round(s.x * self.sx, 2), y=round(s.y * self.sy, 2), visible=1)
            if s.visible
            else Shuttle()
        )
        players = Players()
        for side in ("near", "far", "near_2", "far_2"):
            p = getattr(f.players, side)
            if p is not None:
                x, y, w, h = p.bbox
                setattr(players, side, Player(
                    bbox=(x * self.sx, y * self.sy, w * self.sx, h * self.sy),
                    keypoints=[(kx * self.sx, ky * self.sy, ks) for kx, ky, ks in p.keypoints],
                    score=p.score,
                ))  # fmt: skip
        return shuttle, players
