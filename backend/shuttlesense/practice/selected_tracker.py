"""Court-independent tracking of a user-selected player.

Appearance and motion are evidence of continuity, not a biometric identity guarantee.
Ambiguous or unconfirmed frames are intentionally returned as unobserved.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from shuttlesense.pose.tracking import appearance_distance, torso_histogram
from shuttlesense.practice.evidence import _iou
from shuttlesense.schema import Player


def _centre(box):
    x, y, w, h = box
    return np.array((x + w / 2, y + h / 2), dtype=float)


@dataclass
class SelectedIdentityTracker:
    bbox: tuple[float, float, float, float]
    max_gap: int = 90
    max_appearance: float = 0.30
    appearance: np.ndarray | None = None
    velocity: np.ndarray = field(default_factory=lambda: np.zeros(2))
    missing: int = 0
    initialized: bool = False
    reference_set: bool = False
    recovery_bbox: tuple[float, float, float, float] | None = None
    recovery_count: int = 0
    competitor_appearances: list[np.ndarray] = field(default_factory=list)
    overlap_uncertain: bool = False

    def update(self, detections: list[Player], frame: np.ndarray) -> Player | None:
        if self.missing > self.max_gap:
            return None
        if not self.reference_set:
            # Anchor appearance to the box the user chose, even if the detector misses it.
            self.appearance = torso_histogram(frame, Player(bbox=self.bbox, score=1.0))
            self.reference_set = True
        candidates = []
        centre = _centre(self.bbox)
        predicted = centre + self.velocity * min(self.missing + 1, 4)
        for player in detections:
            box = player.bbox
            if min(box[2], box[3], self.bbox[2], self.bbox[3]) <= 0:
                continue
            size_ratio = (box[2] * box[3]) / (self.bbox[2] * self.bbox[3])
            if not 0.4 <= size_ratio <= 2.5:
                continue
            distance = float(np.linalg.norm(_centre(box) - predicted)) / max(
                self.bbox[3], box[3], 1
            )
            limit = min(1.2, 0.6 + 0.1 * self.missing)
            overlap = _iou(self.bbox, box)
            if (not self.initialized and overlap < 0.35) or distance > limit:
                continue
            hist = torso_histogram(frame, player)
            if self.appearance is not None and hist is not None:
                appearance = appearance_distance(self.appearance, hist)
                if appearance > self.max_appearance:
                    continue
            else:
                appearance = 0.0
            # Recovery without a usable appearance template cannot establish identity.
            if self.missing and (self.appearance is None or hist is None):
                continue
            candidates.append((distance + appearance + 0.25 * (1 - overlap), player, hist))
        candidates.sort(key=lambda item: item[0])
        if not candidates:
            return self._miss()
        if len(candidates) > 1 and candidates[1][0] - candidates[0][0] < 0.20:
            self.overlap_uncertain = True
            return self._miss()
        _, player, hist = candidates[0]
        # Overlapping detections can have contaminated torso crops or merged keypoints.
        if any(
            other is not player and _iou(player.bbox, other.bbox) > 0.15 for other in detections
        ):
            self.overlap_uncertain = True
            return self._miss()
        if self.missing:
            # A previous crossing with no clean view of the other person cannot be
            # resolved safely from two matching boxes alone.
            if self.overlap_uncertain and not self.competitor_appearances:
                return self._miss()
            if hist is None or self.appearance is None:
                return self._miss()
            target_distance = appearance_distance(self.appearance, hist)
            if any(
                appearance_distance(other, hist) <= target_distance + 0.12
                for other in self.competitor_appearances
            ):
                return self._miss()
            if self.recovery_bbox is None or _iou(self.recovery_bbox, player.bbox) < 0.4:
                self.recovery_count = 1
            else:
                self.recovery_count += 1
            self.recovery_bbox = player.bbox
            if self.recovery_count < 2:
                self.missing += 1
                return None
        displacement = _centre(player.bbox) - centre
        if self.initialized and self.missing == 0:
            self.velocity = 0.5 * self.velocity + 0.5 * displacement
        else:
            self.velocity = np.zeros(2)
        self.bbox = player.bbox
        self.missing = 0
        self.recovery_bbox = None
        self.recovery_count = 0
        self.overlap_uncertain = False
        if hist is not None:
            self.appearance = (
                hist if self.appearance is None else 0.95 * self.appearance + 0.05 * hist
            )
        self.initialized = True
        self._remember_competitors(player, detections, frame)
        return player

    def _remember_competitors(self, selected: Player, detections: list[Player], frame: np.ndarray):
        """Keep clean appearances of other people seen before identity becomes ambiguous."""
        for other in detections:
            if other is selected or _iou(selected.bbox, other.bbox) > 0.01:
                continue
            if any(
                candidate is not other and _iou(other.bbox, candidate.bbox) > 0.01
                for candidate in detections
            ):
                continue
            hist = torso_histogram(frame, other)
            if hist is None or any(
                appearance_distance(hist, known) < 0.10 for known in self.competitor_appearances
            ):
                continue
            if len(self.competitor_appearances) < 8:
                self.competitor_appearances.append(hist)

    def _miss(self) -> None:
        self.missing += 1
        self.recovery_bbox = None
        self.recovery_count = 0
        return None
