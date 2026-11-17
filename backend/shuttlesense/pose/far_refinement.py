"""Run a focused pretrained pose pass when an already locked far player is missing."""

from __future__ import annotations

import math
from typing import Any

import numpy as np

from shuttlesense.court import court_to_image, image_to_court
from shuttlesense.court.lines import play_bounds
from shuttlesense.pose.tracking import foot_point
from shuttlesense.schema import Player


class FarPlayerRefiner:
    """Use the same detector on a court-derived crop during short far-player gaps."""

    def __init__(self, cfg: dict[str, Any], court: str, size: tuple[float, float]):
        self.enabled = bool(cfg.get("far_refinement_enabled", True))
        self.hold_frames = max(1, int(cfg.get("far_refinement_hold_frames", 12)))
        self.max_missing = max(1, int(cfg.get("far_refinement_max_missing", 45)))
        self.remaining = 0
        self.court = court
        self.size = size
        self.min_score = float(cfg.get("min_person_score", 0.4))
        self.margin = float(cfg.get("far_locked_jump_margin_m", 1.5))
        self.side_margin = float(cfg.get("locked_jump_margin_m", 0.3))

    def refine(
        self,
        frame: np.ndarray,
        detect,
        tracker,
        people: list[Player],
        *,
        homography: np.ndarray | None,
        scale: tuple[float, float] = (1, 1),
    ) -> list[Player]:
        if not self.enabled or homography is None:
            return people
        far = [track for name, track in tracker.slots.items() if name.startswith("far")]
        # Never bootstrap an unknown person from the crop; it only helps locked identities.
        if not far or not all(track.locked for track in far):
            self.remaining = 0
            return people
        if any(0 < track.missing <= self.max_missing for track in far):
            self.remaining = self.hold_frames
        if self.remaining <= 0:
            return people
        self.remaining -= 1

        height, width = frame.shape[:2]
        sx, sy = scale
        xmin, xmax, ymin, ymax = play_bounds(self.court, self.size)
        net = (ymin + ymax) / 2
        try:
            points = court_to_image(
                homography, np.array([[xmin, net], [xmax, net], [xmax, ymax], [xmin, ymax]])
            )
        except (ValueError, np.linalg.LinAlgError):
            return people
        if not np.isfinite(points).all() or sx <= 0 or sy <= 0:
            return people
        points = points / np.array([sx, sy])
        x0 = max(0, int(math.floor(points[:, 0].min() - width * 0.02)))
        x1 = min(width, int(math.ceil(points[:, 0].max() + width * 0.02)))
        y0 = max(0, int(math.floor(points[:, 1].min() - height * 0.25)))
        y1 = min(height, int(math.ceil(points[:, 1].max() + height * 0.02)))
        if x1 - x0 < 32 or y1 - y0 < 32:
            return people
        crop = frame[y0:y1, x0:x1]
        extra = []
        for p in detect(crop):
            if p.score < self.min_score:
                continue
            x, y, w, h = p.bbox
            # Reject clipped bodies: they can be fragments of a near-side player.
            if x < 0 or y < 0 or x + w > x1 - x0 or y + h > y1 - y0:
                continue
            translated = Player(
                bbox=((x + x0) * sx, (y + y0) * sy, w * sx, h * sy),
                keypoints=[
                    ((kx + x0) * sx, (ky + y0) * sy, score) for kx, ky, score in p.keypoints
                ],
                score=p.score,
            )
            ankles = [(x, y) for x, y, score in translated.keypoints[15:17] if score >= 0.3]
            anchor = np.mean(ankles, axis=0) if ankles else foot_point(translated)
            xy = image_to_court(homography, np.array([anchor]))[0]
            if (
                np.isfinite(xy).all()
                and xmin - self.side_margin <= xy[0] <= xmax + self.side_margin
                and net + 0.25 <= xy[1] <= ymax + self.margin
            ):
                extra.append(translated)
        return [*people, *extra]
