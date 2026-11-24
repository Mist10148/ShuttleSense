"""Court-independent tracking of a user-selected player.

Appearance and motion are evidence of continuity, not a biometric identity guarantee.
Ambiguous or unconfirmed frames are intentionally returned as unobserved.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

from shuttlesense.pose.player_tracker import _bbox_iou as _iou
from shuttlesense.pose.player_tracker import box_center, box_step_limit, has_match_tie, torso_center
from shuttlesense.pose.tracking import appearance_distance, torso_histogram
from shuttlesense.schema import Player


@dataclass
class _Rival:
    player: Player
    centre: np.ndarray
    torso: np.ndarray | None
    appearance: np.ndarray | None
    velocity: np.ndarray = field(default_factory=lambda: np.zeros(2))
    missing: int = 0
    observations: int = 1


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
    image_cfg: dict = field(default_factory=dict)
    torso: np.ndarray | None = None
    torso_velocity: np.ndarray = field(default_factory=lambda: np.zeros(2))
    selection_appearance: np.ndarray | None = None
    rivals: list[_Rival] = field(default_factory=list)
    overlap_active: bool = False
    recovery_required: int = 2

    def lock_selection(self, detections: list[Player], frame: np.ndarray) -> Player | None:
        """Only the explicitly selected detection may initialize the practice track."""
        ranked = sorted(
            ((_iou(self.bbox, player.bbox), player) for player in detections),
            key=lambda pair: pair[0],
            reverse=True,
        )
        if not ranked or ranked[0][0] < 0.35:
            return None
        if len(ranked) > 1 and ranked[0][0] - ranked[1][0] < 0.15:
            return None
        selected = ranked[0][1]
        self.bbox = selected.bbox
        self.appearance = torso_histogram(frame, selected)
        self.selection_appearance = self.appearance
        self.torso = torso_center(selected)
        self.reference_set = self.initialized = True
        self._remember_competitors(selected, detections, frame)
        self._advance_rivals(selected, detections, {}, {}, frame)
        return selected

    def update(self, detections: list[Player], frame: np.ndarray) -> Player | None:
        if self.missing > self.max_gap:
            return None
        if not self.reference_set:
            # Anchor appearance to the box the user chose, even if the detector misses it.
            self.appearance = torso_histogram(frame, Player(bbox=self.bbox, score=1.0))
            self.reference_set = True
        candidates = []
        centre = box_center(self.bbox)
        predicted = centre + self.velocity * min(self.missing + 1, 4)
        torso_prediction = None
        if self.torso is not None and self.missing <= 3:
            torso_prediction = self.torso + self.torso_velocity * (self.missing + 1)
        torsos = {id(player): torso_center(player) for player in detections}
        centres = {id(player): box_center(player.bbox) for player in detections}
        histograms = {}

        def histogram(player):
            key = id(player)
            if key not in histograms:
                histograms[key] = torso_histogram(frame, player)
            return histograms[key]

        rival_matches = self._rival_matches(detections, centres, torsos, histogram)
        torso_costs = {}

        def miss():
            self._advance_rivals(None, detections, rival_matches, torsos, frame, histogram)
            return self._miss()

        def torso_distance(player):
            key = id(player)
            anchor = torsos[key]
            if torso_prediction is None or anchor is None:
                return float("inf")
            if key not in torso_costs:
                torso_costs[key] = float(np.linalg.norm(anchor - torso_prediction)) / max(
                    self.bbox[3], 1
                )
            return torso_costs[key]

        def separated(player, rivals):
            # A short overlap of boxes is normal in doubles. Trust the established
            # torso trajectory only when the other visible torsos are clearly separate.
            target = torso_distance(player)
            return (
                target <= 0.18
                and bool(rivals)
                and all(
                    np.isfinite(torso_distance(other)) and torso_distance(other) >= target + 0.18
                    for other in rivals
                )
            )

        for player in detections:
            box = player.bbox
            if min(box[2], box[3], self.bbox[2], self.bbox[3]) <= 0:
                continue
            size_ratio = (box[2] * box[3]) / (self.bbox[2] * self.bbox[3])
            if not 0.4 <= size_ratio <= 2.5:
                continue
            distance = float(np.linalg.norm(centres[id(player)] - predicted)) / max(
                self.bbox[3], box[3], 1
            )
            limit = box_step_limit(self.image_cfg, self.missing)
            overlap = _iou(self.bbox, box)
            if (not self.initialized and overlap < 0.35) or distance > limit:
                continue
            hist = histogram(player)
            if self.appearance is not None and hist is not None:
                appearance = appearance_distance(self.appearance, hist)
                if self.missing and self.selection_appearance is not None:
                    appearance = max(
                        appearance, appearance_distance(self.selection_appearance, hist)
                    )
                overlaps = [
                    other
                    for other in detections
                    if other is not player and _iou(box, other.bbox) > 0.15
                ]
                if appearance > self.max_appearance and not separated(player, overlaps):
                    continue
            else:
                appearance = 0.0
            # Recovery without a usable appearance template cannot establish identity.
            if self.missing and (self.appearance is None or hist is None):
                continue
            torso_cost = torso_distance(player)
            candidates.append(
                (
                    distance
                    + appearance
                    + 0.25 * (1 - overlap)
                    + (min(torso_cost, 1.0) if torso_prediction is not None else 0),
                    player,
                    hist,
                )
            )
        candidates.sort(key=lambda item: item[0])
        if not candidates:
            return miss()
        cost, player, hist = candidates[0]
        rival_claims = [
            score
            for edges in rival_matches.values()
            for score, rival_candidate in edges
            if rival_candidate is player and score - edges[0][0] < 0.15
        ]
        if has_match_tie(cost, rival_claims, 0.15):
            self.overlap_uncertain = self.overlap_active = True
            self.recovery_required = 3
            return miss()

        def independently_matched(other):
            return any(
                edges[0][1] is other
                and not has_match_tie(edges[0][0], (score for score, _ in edges[1:]), 0.15)
                for edges in rival_matches.values()
            )

        def distinct_trajectories(others):
            return (
                torso_distance(player) <= 0.18
                and bool(others)
                and all(
                    torso_distance(other) >= torso_distance(player) + 0.10
                    and np.isfinite(torso_distance(other))
                    and independently_matched(other)
                    for other in others
                )
            )

        if (
            len(candidates) > 1
            and has_match_tie(cost, (c[0] for c in candidates[1:]), 0.20)
            and not separated(player, [c[1] for c in candidates[1:]])
            and not distinct_trajectories([c[1] for c in candidates[1:] if c[0] < cost + 0.20])
        ):
            self.overlap_uncertain = self.overlap_active = True
            self.recovery_required = 3 if rival_claims else self.recovery_required
            return miss()
        # Overlapping detections can have contaminated torso crops or merged keypoints.
        overlapping = [
            other
            for other in detections
            if other is not player and _iou(player.bbox, other.bbox) > 0.15
        ]
        self.overlap_active = bool(overlapping)
        if (
            overlapping
            and not separated(player, overlapping)
            and not distinct_trajectories(overlapping)
        ):
            self.overlap_uncertain = True
            self.recovery_required = 3 if rival_claims else self.recovery_required
            return miss()
        if self.missing:
            # A previous crossing with no clean view of the other person cannot be
            # resolved safely from two matching boxes alone.
            if self.overlap_uncertain and not self.competitor_appearances:
                return miss()
            if hist is None or self.appearance is None:
                return miss()
            target_distance = appearance_distance(self.appearance, hist)
            if any(
                appearance_distance(other, hist) <= target_distance + 0.12
                for other in self.competitor_appearances
            ) and not separated(
                player,
                [
                    other
                    for other in detections
                    if other is not player
                    and abs(float(box_center(other.bbox)[1] - box_center(player.bbox)[1]))
                    < self.bbox[3]
                    and 0.65 <= other.bbox[3] / player.bbox[3] <= 1.5
                ],
            ):
                return miss()
            if rival_claims:
                self.recovery_required = 3
            if self.recovery_bbox is None or _iou(self.recovery_bbox, player.bbox) < 0.4:
                self.recovery_count = 1
            else:
                self.recovery_count += 1
            self.recovery_bbox = player.bbox
            if self.recovery_count < self.recovery_required:
                self._advance_rivals(
                    player, detections, rival_matches, torsos, frame, histogram, seed=False
                )
                self.missing += 1
                return None
        displacement = box_center(player.bbox) - centre
        if self.initialized and self.missing == 0:
            self.velocity = 0.5 * self.velocity + 0.5 * displacement
        else:
            self.velocity = np.zeros(2)
        anchor = torsos[id(player)]
        if anchor is not None and self.torso is not None and not self.missing:
            self.torso_velocity = 0.5 * self.torso_velocity + 0.5 * (anchor - self.torso)
        else:
            self.torso_velocity = np.zeros(2)
        self.torso = anchor
        self.bbox = player.bbox
        self.missing = 0
        self.recovery_bbox = None
        self.recovery_count = 0
        self.recovery_required = 2
        self.overlap_uncertain = False
        if hist is not None and not overlapping:
            self.appearance = (
                hist if self.appearance is None else 0.95 * self.appearance + 0.05 * hist
            )
        self.initialized = True
        self._remember_competitors(player, detections, frame, histogram)
        self._advance_rivals(player, detections, rival_matches, torsos, frame, histogram)
        return player

    def _rival_matches(self, detections, centres, torsos, histogram):
        matches = {}
        for i, rival in enumerate(self.rivals):
            if rival.observations < 2 and rival.missing:
                continue
            edges = []
            predicted = rival.centre + rival.velocity * min(rival.missing + 1, 4)
            bh = rival.player.bbox[3]
            for player in detections:
                height = player.bbox[3]
                if not 0.65 * bh <= height <= 1.5 * bh:
                    continue
                distance = float(np.linalg.norm(centres[id(player)] - predicted)) / max(bh, height)
                if distance > min(0.5, box_step_limit(self.image_cfg, rival.missing)):
                    continue
                hist = histogram(player)
                appearance = appearance_distance(rival.appearance, hist)
                if appearance > self.max_appearance:
                    continue
                torso = torsos[id(player)]
                torso_cost = 0.0
                if torso is not None and rival.torso is not None:
                    expected = rival.torso + rival.velocity * min(rival.missing + 1, 4)
                    torso_cost = min(1, float(np.linalg.norm(torso - expected)) / bh)
                score = distance + appearance + 0.25 * (1 - _iou(rival.player.bbox, player.bbox))
                edges.append((score + torso_cost, player))
            if edges:
                matches[i] = sorted(edges, key=lambda edge: edge[0])
        return matches

    def _advance_rivals(
        self, selected, detections, matches, torsos, frame, histogram=None, *, seed=True
    ):
        assigned = {id(selected)}
        accepted = set()
        # Reserve a detection once, and leave rival ties unresolved as well.
        ranked = sorted((edges[0][0], i, edges[0][1]) for i, edges in matches.items())
        for cost, i, player in ranked:
            if id(player) in assigned:
                continue
            others = [c for c, k, p in ranked if k != i and p is player]
            if has_match_tie(cost, [*others, *(c for c, _ in matches[i][1:])], 0.15):
                continue
            if selected is None and _iou(self.bbox, player.bbox) > 0.15:
                # Do not teach a rival that it owns the obscured target's last box.
                continue
            rival = self.rivals[i]
            centre = box_center(player.bbox)
            rival.velocity = 0.5 * rival.velocity + 0.5 * (centre - rival.centre)
            rival.centre, rival.player = centre, player
            rival.torso, rival.missing = torsos[id(player)], 0
            rival.observations += 1
            assigned.add(id(player))
            accepted.add(i)

        for i, rival in enumerate(self.rivals):
            if i not in accepted:
                rival.missing += 1
        self.rivals = [track for track in self.rivals if track.missing <= 8]
        if selected is None or not seed or self.overlap_active or len(self.rivals) >= 3:
            return
        centre = box_center(selected.bbox)
        nearby = sorted(
            (
                (float(np.linalg.norm(box_center(p.bbox) - centre)), j, p)
                for j, p in enumerate(detections)
                if id(p) not in assigned and 0.65 <= p.bbox[3] / selected.bbox[3] <= 1.5
            ),
            key=lambda entry: entry[:2],
        )
        for distance, _, player in nearby:
            if distance > 2 * selected.bbox[3] or _iou(selected.bbox, player.bbox) > 0.01:
                continue
            if any(_iou(rival.player.bbox, player.bbox) > 0.15 for rival in self.rivals):
                continue
            hist = histogram(player) if histogram is not None else torso_histogram(frame, player)
            self.rivals.append(_Rival(player, box_center(player.bbox), torso_center(player), hist))
            if len(self.rivals) == 3:
                break

    def _remember_competitors(self, selected, detections, frame, histogram=None):
        """Keep clean appearances of other people seen before identity becomes ambiguous."""
        for other in detections:
            if other is selected or _iou(selected.bbox, other.bbox) > 0.01:
                continue
            if any(
                candidate is not other and _iou(other.bbox, candidate.bbox) > 0.01
                for candidate in detections
            ):
                continue
            hist = histogram(other) if histogram is not None else torso_histogram(frame, other)
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
