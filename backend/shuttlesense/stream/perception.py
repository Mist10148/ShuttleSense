"""Per-frame perception for live sessions: shuttle and players for the newest frame.

ModelPerception runs the same models and helpers as the offline tracking and pose stages,
frame by frame: TrackNetV3 over a sliding window of its last seq_len frames (so a frame's
shuttle is known as soon as it arrives), and the pose detector plus the near/far tracker.
Live-only differences, all documented in docs/ARCHITECTURE.md: the background median comes
from the first frames instead of the whole clip, InpaintNet and centred smoothing are off
(they need future frames), and outliers are not removed.
"""

from __future__ import annotations

from collections import deque
from collections.abc import Sequence
from typing import Any, Protocol

import numpy as np

from shuttlesense.schema import ClipRecord, Player, Players, Shuttle


class Perception(Protocol):
    available: dict[str, bool]

    def __call__(self, frame: np.ndarray, index: int) -> tuple[Shuttle, Players]: ...


def scale_players(players: Players, s: float) -> Players:
    """Players with every pixel coordinate multiplied by s."""
    out = Players()
    for side in ("near", "far"):
        p = getattr(players, side)
        if p is not None:
            x, y, w, h = p.bbox
            setattr(out, side, Player(
                bbox=(x * s, y * s, w * s, h * s),
                keypoints=[(kx * s, ky * s, ks) for kx, ky, ks in p.keypoints],
                score=p.score,
            ))  # fmt: skip
    return out


class ModelPerception:
    """TrackNetV3 + pose on live frames; a part whose weights or packages are missing is off."""

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
        from shuttlesense.pose.estimator import load_detector
        from shuttlesense.pose.tracking import PlayerTracker
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
        self.tracker = PlayerTracker(hold_frames=cfg.get("hold_frames", 5))
        self.court_size = tuple(court_cfg.get("court_size_m", COURT_SIZE_M))
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

        if self.bg_mode and len(self.bg_samples) < self.background_frames:
            self.bg_samples.append(cv2.resize(frame, INPUT_SIZE)[:, :, ::-1])
            self.median = np.median(np.stack(self.bg_samples), axis=0).astype(np.uint8)
        self.window.append(frame)
        frames = list(self.window)
        frames = [frames[0]] * (self.seq_len - len(frames)) + frames  # pad at the start
        with torch.inference_mode():
            points = track_windows(
                self.model, [frames], self.bg_mode, self.median, self.device, self.size
            )[0]
        x, y, vis = points[-1]
        return Shuttle(x=round(x, 1), y=round(y, 1), visible=1) if vis else Shuttle()

    def _players(self, frame: np.ndarray) -> Players:
        if self.detect is None:
            return Players()
        from shuttlesense.pose.tracking import filter_players

        people = [p for p in self.detect(frame) if p.score >= self.min_person_score]
        people = filter_players(
            people,
            frame_height=frame.shape[0],
            homography=self.homography,
            court_size=self.court_size,
        )
        near, far = self.tracker.update(people)
        return Players(near=near, far=far)


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
        for side in ("near", "far"):
            p = getattr(f.players, side)
            if p is not None:
                x, y, w, h = p.bbox
                setattr(players, side, Player(
                    bbox=(x * self.sx, y * self.sy, w * self.sx, h * self.sy),
                    keypoints=[(kx * self.sx, ky * self.sy, ks) for kx, ky, ks in p.keypoints],
                    score=p.score,
                ))  # fmt: skip
        return shuttle, players
