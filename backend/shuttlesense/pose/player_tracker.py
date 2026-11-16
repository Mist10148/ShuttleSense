"""Conservative player selection shared by live and recorded-video perception."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import numpy as np

from shuttlesense.court.lines import play_bounds
from shuttlesense.pose.tracking import (
    appearance_distance,
    foot_point,
    make_tracker,
    torso_histogram,
    track_players,
)
from shuttlesense.schema import Player, Players


def _bbox_iou(a: tuple[float, ...], b: tuple[float, ...]) -> float:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    intersection = max(0.0, min(ax + aw, bx + bw) - max(ax, bx)) * max(
        0.0, min(ay + ah, by + bh) - max(ay, by)
    )
    union = aw * ah + bw * bh - intersection
    return intersection / union if union > 0 else 0.0


def _same_person_pose(a: Player, b: Player, *, iou_min: float, pose_max: float) -> bool:
    """Only merge strongly overlapping detections with nearly identical upper-body joints."""
    if _bbox_iou(a.bbox, b.bbox) < iou_min:
        return False
    distances = []
    for joint in (0, 5, 6, 11, 12):
        if joint >= len(a.keypoints) or joint >= len(b.keypoints):
            continue
        ak, bk = a.keypoints[joint], b.keypoints[joint]
        if min(ak[2], bk[2]) >= 0.3:
            distances.append(float(np.linalg.norm(np.asarray(ak[:2]) - bk[:2])))
    return (
        len(distances) >= 3 and float(np.mean(distances)) / max(a.bbox[3], b.bbox[3], 1) <= pose_max
    )


@dataclass
class Track:
    pos: np.ndarray | None = None
    # Last trusted floor position, inside the court or in the run-off around it.
    last_pos: np.ndarray | None = None
    bbox: tuple[float, float, float, float] | None = None
    hist: np.ndarray | None = None
    count: int = 0
    locked: bool = False
    missing: int = 0
    recovery_pos: np.ndarray | None = None
    recovery_count: int = 0
    outside_frames: int = 0


class CourtPlayerTracker:
    """Lock each slot only after consistent observations; never recycle a locked identity.

    Positions are in court meters. Missing players are emitted as None, including during
    short occlusions. A slot is only ever seeded inside the playing court, so officials and
    spectators are never picked up; a locked player may then be followed step by step into
    the run-off around the court (`candidate_margin_m`, off when 0), where rear-court and
    wide shots are played from. Without a calibrated court there is no polygon to enforce:
    players are then chosen in image space by the plain trackers of pose/tracking.py, and
    `view_valid` stays False so nothing downstream treats their positions as court positions.
    """

    def __init__(self, cfg: dict[str, Any], court: str, court_size: tuple[float, float]):
        self.court, self.court_size = court, court_size
        self.cfg = cfg
        self._uncalibrated = None
        # 0 keeps the strict policy: outside the lines only the short jump exceptions apply.
        self.runoff = float(cfg.get("candidate_margin_m", 0.0))
        self.confirm = max(1, int(cfg.get("confirmation_frames", 3)))
        self.max_step = float(cfg.get("max_step_m", 0.5))
        self.max_box_step = float(cfg.get("max_step_box_fraction", 0.6))
        self.max_missing = int(cfg.get("max_reacquire_gap_frames", 90))
        self.gap_step = float(cfg.get("reacquire_step_per_frame_m", 0.15))
        self.max_gap_step = float(cfg.get("reacquire_max_step_m", 1.5))
        self.gap_box_step = float(cfg.get("reacquire_box_step_per_frame", 0.1))
        self.max_gap_box_step = float(cfg.get("reacquire_max_box_fraction", 1.2))
        self.recovery_after = int(cfg.get("reacquire_confirm_after_frames", 5))
        self.recovery_confirm = max(1, int(cfg.get("reacquire_confirmation_frames", 2)))
        self.view_valid = False
        # Watch can maintain a confirmed identity by image continuity outside the court.
        # Offline and live retain their existing, stricter boundary policy.
        self.watch_outside_tracking = False
        self.watch_min_iou = float(cfg.get("watch_outside_min_iou", 0.15))
        self.watch_max_missing = int(cfg.get("watch_outside_max_missing_frames", 3))
        self.jump_margin = float(cfg.get("locked_jump_margin_m", 0.3))
        self.jump_max_distance = float(cfg.get("locked_jump_max_distance_m", 0.35))
        self.jump_max_appearance = float(cfg.get("locked_jump_max_appearance", 0.25))
        self.jump_max_missing = int(cfg.get("locked_jump_max_missing_frames", 2))
        self.jump_max_frames = int(cfg.get("locked_jump_max_frames", 9))
        self.far_jump_margin = float(cfg.get("far_locked_jump_margin_m", 1.5))
        self.far_jump_iou = float(cfg.get("far_locked_jump_min_iou", 0.45))
        self.far_jump_max_frames = int(cfg.get("far_locked_jump_max_frames", 18))
        self.far_jump_max_ankle_spread = float(cfg.get("far_jump_max_ankle_spread_m", 2.2))
        self.max_appearance = float(cfg.get("max_appearance_distance", 0.45))
        self.ambiguity = float(cfg.get("match_ambiguity", 0.15))
        self.duplicate_iou = float(cfg.get("duplicate_iou", 0.65))
        self.duplicate_pose = float(cfg.get("duplicate_pose_fraction", 0.1))
        self.slots = {
            name: Track()
            for name in (
                ("near", "far", "near_2", "far_2") if court == "doubles" else ("near", "far")
            )
        }

    def update(
        self,
        people: list[Player],
        *,
        frame_height: float,
        homography: np.ndarray | None,
        frame: np.ndarray | None = None,
        image_scale: tuple[float, float] = (1, 1),
    ) -> Players:
        from shuttlesense.court import image_to_court

        # Without calibrated corners there is no reliable court polygon to enforce.
        if homography is None:
            self.view_valid = False
            if self._uncalibrated is None:
                self._uncalibrated = make_tracker(self.cfg, self.court)
            return track_players(
                self._uncalibrated,
                people,
                frame_height=frame_height,
                frame=frame,
                image_scale=image_scale,
            )
        self.view_valid = True

        candidates = []
        for p in people:
            ankles = [(x, y) for x, y, s in p.keypoints[15:17] if s >= 0.3]
            points = np.asarray(ankles if ankles else [foot_point(p)])
            point = np.mean(points, axis=0)
            if not np.isfinite(point).all():
                continue
            projected = image_to_court(homography, points)
            if not np.isfinite(projected).all():
                continue
            pos = projected.mean(axis=0)
            spread = float(np.linalg.norm(projected[0] - projected[1])) if len(projected) > 1 else 0
            xmin, xmax, ymin, ymax = play_bounds(self.court, self.court_size)
            # Small numerical tolerance only: never extend the playing boundary.
            eps = 1e-5
            inside = all(
                xmin - eps <= x <= xmax + eps and ymin - eps <= y <= ymax + eps
                for x, y in projected
            )
            side = "near" if pos[1] < self.court_size[1] / 2 else "far"
            x_margin = max(self.jump_margin, self.runoff)
            y_margin = max(self.far_jump_margin if side == "far" else self.jump_margin, self.runoff)
            if not self.watch_outside_tracking and not all(
                xmin - x_margin <= x <= xmax + x_margin and ymin - y_margin <= y <= ymax + y_margin
                for x, y in projected
            ):
                continue
            hist = torso_histogram(frame, p, image_scale) if frame is not None else None
            candidates.append((p, pos, hist, inside, side, spread))

        # RTMPose can return several near-identical poses for one far-side person during
        # overlap. They are not independent people and must not create a false match tie.
        unique = []
        for candidate in sorted(candidates, key=lambda c: (c[3], c[0].score), reverse=True):
            if not any(
                candidate[4] == kept[4]
                and _same_person_pose(
                    candidate[0], kept[0], iou_min=self.duplicate_iou, pose_max=self.duplicate_pose
                )
                for kept in unique
            ):
                unique.append(candidate)
        candidates = unique

        output: dict[str, Player | None] = dict.fromkeys(self.slots)
        used: set[int] = set()
        # Prefer existing identities. Reject distant, visually incompatible or ambiguous matches.
        pairs = []
        runoff_pairs: set[tuple[str, int]] = set()
        limit = self.max_step
        for name, track in self.slots.items():
            if track.pos is None or track.missing > self.max_missing:
                continue
            # A player can move while occluded. Widen the matching gate gradually, not
            # on the first missed frame, and keep it bounded to prevent instant jumps.
            allowed_step = min(self.max_gap_step, self.max_step + track.missing * self.gap_step)
            allowed_box_step = min(
                self.max_gap_box_step, self.max_box_step + track.missing * self.gap_box_step
            )
            for j, (person, pos, hist, inside, side, spread) in enumerate(candidates):
                if not track.locked and not inside:
                    continue
                if not name.startswith(side):
                    continue
                # A mixed pose can combine the feet of two overlapping far players.
                # Do not accept it as a landing immediately after a locked jump.
                if (
                    side == "far"
                    and inside
                    and track.outside_frames > 0
                    and spread > self.far_jump_max_ankle_spread
                ):
                    continue
                anchor = track.last_pos if track.last_pos is not None else track.pos
                dist = float(np.linalg.norm(pos - anchor))
                if track.bbox is not None:
                    x, y, w, h = track.bbox
                    nx, ny, nw, nh = person.bbox
                    box_dist = np.hypot(nx + nw / 2 - x - w / 2, ny + nh / 2 - y - h / 2)
                    if box_dist > allowed_box_step * max(h, nh, 1):
                        continue
                appearance = appearance_distance(track.hist, hist)
                far_continuity = (
                    side == "far"
                    and track.locked
                    and track.missing <= self.jump_max_missing
                    and track.bbox is not None
                    and track.hist is not None
                    and hist is not None
                    and appearance <= self.jump_max_appearance
                    and _bbox_iou(track.bbox, person.bbox) >= self.far_jump_iou
                )
                # For Watch, established tracks can continue outside the court using
                # consecutive image observations. Court-plane distances are unreliable
                # for a jumping person, so do not compare their projected feet to the
                # last trusted floor position. Never seed identities from these candidates.
                watch_continuity = (
                    self.watch_outside_tracking
                    and track.locked
                    and (not inside or track.outside_frames > 0)
                    and track.missing <= self.watch_max_missing
                    and track.bbox is not None
                    and track.hist is not None
                    and hist is not None
                    and appearance <= self.jump_max_appearance
                    and _bbox_iou(track.bbox, person.bbox) >= self.watch_min_iou
                )
                # A locked player walking or lunging off the court keeps their identity as
                # long as each step from the last trusted floor position is a plausible one.
                runoff = (
                    not inside
                    and self.runoff > 0
                    and not self.watch_outside_tracking
                    and track.locked
                    and dist <= allowed_step
                    and (track.hist is None or hist is None or appearance <= self.max_appearance)
                )
                if not inside and self.watch_outside_tracking:
                    if not watch_continuity:
                        continue
                elif runoff:
                    runoff_pairs.add((name, j))
                elif not inside:
                    if side == "far":
                        if not far_continuity or track.outside_frames >= self.far_jump_max_frames:
                            continue
                    elif (
                        not track.locked
                        or track.missing > self.jump_max_missing
                        or track.outside_frames >= self.jump_max_frames
                        or track.hist is None
                        or hist is None
                        or dist > self.jump_max_distance
                        or appearance > self.jump_max_appearance
                    ):
                        continue
                if track.locked and track.missing and (track.hist is None or hist is None):
                    continue
                compatible = track.hist is None or hist is None or appearance <= self.max_appearance
                jump_match = far_continuity and (
                    not inside or (track.outside_frames > 0 and dist <= self.max_gap_step)
                )
                if (dist <= allowed_step or jump_match or watch_continuity) and compatible:
                    if watch_continuity:
                        # Compare competing outside candidates in image space. Projected
                        # floor coordinates may be arbitrarily distorted during a jump.
                        dist = (1 - _bbox_iou(track.bbox, person.bbox)) * limit
                    pairs.append((dist + appearance * limit, name, j))
        pairs.sort()
        matched: set[str] = set()
        for cost, name, j in pairs:
            if name in matched or j in used:
                continue
            track = self.slots[name]
            alternatives = [c for c, n, k in pairs if n == name and k != j and k not in used]
            rivals = [c for c, n, k in pairs if k == j and n != name and n not in matched]
            ambiguous = (alternatives and min(alternatives) - cost < self.ambiguity * limit) or (
                rivals and min(rivals) - cost < self.ambiguity * limit
            )
            if track.locked and ambiguous:
                continue
            p, pos, hist, inside, _, _ = candidates[j]
            if not inside:
                p = p.model_copy(update={"court_position_valid": False})
            if track.locked and track.missing >= self.recovery_after:
                if (
                    track.recovery_pos is None
                    or float(np.linalg.norm(pos - track.recovery_pos)) > self.max_step
                ):
                    track.recovery_count = 0
                track.recovery_pos = pos
                track.recovery_count += 1
                if track.recovery_count < self.recovery_confirm:
                    track.missing += 1
                    used.add(j)
                    matched.add(name)
                    continue
            if inside:
                track.pos = track.last_pos = pos
            elif (name, j) in runoff_pairs:
                track.last_pos = pos
            track.missing = 0
            track.outside_frames = 0 if inside else track.outside_frames + 1
            track.bbox = p.bbox
            track.recovery_pos, track.recovery_count = None, 0
            # Do not let an uncertain outside observation overwrite the identity template.
            if inside or not self.watch_outside_tracking:
                track.hist = (
                    hist
                    if track.hist is None
                    else (track.hist if hist is None else 0.9 * track.hist + 0.1 * hist)
                )
            track.count += 1
            track.locked = track.locked or track.count >= self.confirm
            if track.locked:
                output[name] = p
            used.add(j)
            matched.add(name)

        for name, track in self.slots.items():
            if name in matched:
                continue
            track.missing += 1
            track.recovery_pos, track.recovery_count = None, 0
            if not track.locked:
                track.pos, track.bbox, track.hist, track.count = None, None, None, 0
                track.last_pos = None

        # Seed unoccupied slots from inside the entry area. Stable spatial ordering gives
        # doubles slots predictable initial identities; never seed a previously locked slot.
        for side in ("near", "far"):
            free = [
                n
                for n, t in self.slots.items()
                if n.startswith(side) and not t.locked and n not in matched
            ]
            contested = {j for _, name, j in pairs if self.slots[name].locked}
            available = [
                j
                for j, c in enumerate(candidates)
                if j not in used and j not in contested and c[3] and c[4] == side
            ]
            available.sort(key=lambda j: candidates[j][1][0])
            for name, j in zip(free, available, strict=False):
                p, pos, hist, _, _, _ = candidates[j]
                t = self.slots[name]
                t.pos, t.hist, t.count, t.missing = pos, hist, 1, 0
                t.last_pos = pos
                t.bbox = p.bbox
                t.locked = self.confirm == 1
                if t.locked:
                    output[name] = p
                used.add(j)
        return Players(**output)
