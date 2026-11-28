"""Keep all four doubles players on the court plane (D66).

`CourtPlayerTracker` locks each slot conservatively. That keeps spectators out, but in
doubles a player it loses for longer than `max_reacquire_gap_frames` is gone for the rest of
the clip (a locked slot is never seeded again), and partners who come close are emitted as
None rather than resolved. `DoublesSlotKeeper` wraps it without changing it:

- Each output slot gets a constant-velocity (alpha-beta, a steady-state Kalman) filter in
  court metres, so its position can be predicted through an occlusion.
- A slot the tracker leaves empty is filled from the detections nobody used on that half:
  one optimal assignment per half (Hungarian, `scipy.optimize.linear_sum_assignment`) with
  a gate that widens while the player is missing, and shirt colour as a tie-breaker. After
  a long loss the slot re-seeds only from a person inside the court, seen in the same spot
  for `reseed_frames` frames, whose height suits that spot (so a seated official, a ball
  kid or a spectator does not take it).
- When the tracker's two partners on a half match the predictions better the other way
  round, for `swap_confirm_frames` frames once they are apart again, the pair is swapped
  for the rest of the clip; while they are close their colour templates are not updated.

It never invents a pose: an empty slot stays None when no detection fits. Singles and
clips without calibration pass through unchanged. References: SoccerNet Game State
Reconstruction (Somers et al., CVPRW 2024) for tracking on the field plane; "Bridging the
Gap: doubles badminton analysis with singles-trained models" (2025) for re-identifying a
partner near the predicted position after a gap.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

import numpy as np

from shuttlesense.court.lines import play_bounds
from shuttlesense.pose.tracking import appearance_distance, foot_point, torso_histogram
from shuttlesense.schema import Player, Players

KEEPER_DEFAULTS: dict[str, Any] = {
    "enabled": True,
    "alpha": 0.6,  # position gain of the alpha-beta filter
    "beta": 0.2,  # velocity gain
    "velocity_decay": 0.85,  # per missing frame: a lost player is not assumed to keep running
    "gate_m": 0.8,  # how far from the prediction a fill may be
    "gate_per_frame_m": 0.08,  # ...growing by this per missing frame
    "max_gate_m": 2.5,  # ...up to this
    "appearance_weight": 1.0,  # metres of cost per unit of colour distance
    "max_appearance": 0.5,  # a fill must look like the player when both colours are known
    "max_coast_frames": 150,  # after this long a slot re-seeds instead of being followed
    "reseed_frames": 3,  # a re-seed needs this many frames in the same spot
    "reseed_step_m": 0.5,  # ...moving at most this per frame
    "side_margin_m": 0.5,  # fills may be this far outside the sidelines
    "back_margin_m": 1.5,  # ...and this far behind the baseline
    "height_m": 1.75,  # a standing player, for the height prior
    "min_height_ratio": 0.45,  # box height / expected height for a re-seed
    "max_height_ratio": 2.2,
    "close_m": 0.6,  # partners this close: colour templates are not updated
    "apart_m": 1.0,  # partners at least this far apart can be swapped
    "swap_margin_m": 0.6,  # the swapped pairing must be this much cheaper
    "swap_confirm_frames": 2,
    "swap_max_missing": 5,  # both tracks seen this recently to judge a swap
}

PAIRS = {"near": ("near", "near_2"), "far": ("far", "far_2")}


def keeper_config(cfg: dict[str, Any] | None) -> dict[str, Any]:
    """stages.pose.doubles_keeper merged over the defaults."""
    return {**KEEPER_DEFAULTS, **((cfg or {}).get("doubles_keeper") or {})}


def with_doubles_keeper(tracker: Any, cfg: dict[str, Any] | None) -> Any:
    """The tracker, wrapped in a DoublesSlotKeeper for doubles when enabled."""
    kc = keeper_config(cfg)
    if getattr(tracker, "court", None) != "doubles" or not kc["enabled"]:
        return tracker
    return DoublesSlotKeeper(tracker, kc)


@dataclass
class _Slot:
    pos: np.ndarray | None = None  # court metres
    vel: np.ndarray = field(default_factory=lambda: np.zeros(2))
    hist: np.ndarray | None = None
    missing: int = 0
    pending: np.ndarray | None = None  # a possible re-seed position
    pending_count: int = 0

    def predict(self) -> np.ndarray | None:
        return None if self.pos is None else self.pos + self.vel


def _iou(a: tuple[float, ...], b: tuple[float, ...]) -> float:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    w = max(0.0, min(ax + aw, bx + bw) - max(ax, bx))
    h = max(0.0, min(ay + ah, by + bh) - max(ay, by))
    inter = w * h
    union = aw * ah + bw * bh - inter
    return inter / union if union > 0 else 0.0


@dataclass
class _Candidate:
    player: Player
    pos: np.ndarray
    side: str
    inside: bool  # within the playing area (doubles lines)
    hist: np.ndarray | None
    height_ok: bool


class DoublesSlotKeeper:
    """A CourtPlayerTracker that keeps all four doubles slots filled when it can (D66)."""

    _OWN = ("inner", "kc", "keep", "perm", "swap_votes")

    def __init__(self, inner: Any, kc: dict[str, Any]):
        object.__setattr__(self, "inner", inner)
        object.__setattr__(self, "kc", kc)
        object.__setattr__(self, "keep", {name: _Slot() for name in inner.slots})
        object.__setattr__(self, "perm", {"near": False, "far": False})  # partners swapped
        object.__setattr__(self, "swap_votes", {"near": 0, "far": 0})

    # The wrapped tracker's state (slots, view_valid, court, ...) stays the one others see:
    # the far-court refiner and Watch's candidate filter read it, Watch sets flags on it.
    def __getattr__(self, name: str) -> Any:
        return getattr(self.inner, name)

    def __setattr__(self, name: str, value: Any) -> None:
        if name in self._OWN:
            object.__setattr__(self, name, value)
        else:
            setattr(self.inner, name, value)

    def update(
        self,
        people: list[Player],
        *,
        frame_height: float,
        homography: np.ndarray | None,
        frame: np.ndarray | None = None,
        image_scale: tuple[float, float] = (1, 1),
    ) -> Players:
        players = self.inner.update(people, frame_height=frame_height, homography=homography,
                                    frame=frame, image_scale=image_scale)  # fmt: skip
        if homography is None:
            return players
        out: dict[str, Player | None] = {name: getattr(players, name) for name in self.keep}
        for half, (a, b) in PAIRS.items():
            if self.perm[half]:
                out[a], out[b] = out[b], out[a]
        candidates = self._candidates(people, homography, frame, image_scale)
        self._resolve_swaps(out, candidates)
        self._fill(out, candidates)
        self._observe(out, candidates)
        return Players(**out)

    def _locate(self, p: Player, homography: np.ndarray) -> np.ndarray | None:
        from shuttlesense.court import image_to_court

        ankles = [(x, y) for x, y, s in p.keypoints[15:17] if s >= 0.3]
        points = np.asarray(ankles if ankles else [foot_point(p)], dtype=float)
        if not np.isfinite(points).all():
            return None
        projected = image_to_court(homography, points)
        if not np.isfinite(projected).all():
            return None
        return projected.mean(axis=0)

    def _height_ok(self, p: Player, pos: np.ndarray, homography: np.ndarray) -> bool:
        """Whether the box is a plausible standing height for a person at `pos`.

        Pixels per metre come from the court plane around the feet; an upright person is
        drawn at about that scale. Loose bounds: only clearly wrong sizes are rejected.
        """
        from shuttlesense.court import court_to_image

        kc = self.kc
        x, y = float(pos[0]), float(pos[1])
        ends = court_to_image(homography, np.array([[x - 0.5, y], [x + 0.5, y]]))
        if not np.isfinite(ends).all():
            return True
        ppm = float(np.linalg.norm(ends[1] - ends[0]))
        if ppm <= 0:
            return True
        ratio = p.bbox[3] / (ppm * float(kc["height_m"]))
        return float(kc["min_height_ratio"]) <= ratio <= float(kc["max_height_ratio"])

    def _candidates(
        self,
        people: list[Player],
        homography: np.ndarray,
        frame: np.ndarray | None,
        image_scale: tuple[float, float],
    ) -> list[_Candidate]:
        kc = self.kc
        xmin, xmax, ymin, ymax = play_bounds(self.inner.court, self.inner.court_size)
        net = self.inner.court_size[1] / 2
        side_m, back_m = float(kc["side_margin_m"]), float(kc["back_margin_m"])
        out = []
        for p in people:
            pos = self._locate(p, homography)
            if pos is None:
                continue
            x, y = float(pos[0]), float(pos[1])
            if not (xmin - side_m <= x <= xmax + side_m and ymin - back_m <= y <= ymax + back_m):
                continue
            inside = xmin <= x <= xmax and ymin <= y <= ymax
            hist = torso_histogram(frame, p, image_scale) if frame is not None else None
            out.append(_Candidate(p, pos, "near" if y < net else "far", inside, hist,
                                  self._height_ok(p, pos, homography)))  # fmt: skip
        return out

    def _taken(self, c: _Candidate, out: dict[str, Player | None]) -> bool:
        """The detection (or a near-identical pose of it) is already in a slot."""
        return any(p is not None and _iou(p.bbox, c.player.bbox) >= 0.5 for p in out.values())

    def _resolve_swaps(self, out: dict[str, Player | None], candidates: list[_Candidate]) -> None:
        kc = self.kc
        pos_of = {id(c.player): c for c in candidates}
        for half, (a, b) in PAIRS.items():
            pa, pb = out[a], out[b]
            ka, kb = self.keep[a], self.keep[b]
            ca = pos_of.get(id(pa)) if pa is not None else None
            cb = pos_of.get(id(pb)) if pb is not None else None
            if (
                ca is None
                or cb is None
                or ka.pos is None
                or kb.pos is None
                or max(ka.missing, kb.missing) > int(kc["swap_max_missing"])
                or float(np.linalg.norm(ca.pos - cb.pos)) < float(kc["apart_m"])
            ):
                self.swap_votes[half] = 0
                continue
            w = float(kc["appearance_weight"])

            def cost(slot: _Slot, c: _Candidate, w: float = w) -> float:
                pred = slot.predict()
                assert pred is not None
                return float(np.linalg.norm(c.pos - pred)) + w * appearance_distance(
                    slot.hist, c.hist
                )

            keep, swap = cost(ka, ca) + cost(kb, cb), cost(ka, cb) + cost(kb, ca)
            if swap + float(kc["swap_margin_m"]) < keep:
                self.swap_votes[half] += 1
            else:
                self.swap_votes[half] = 0
            if self.swap_votes[half] >= int(kc["swap_confirm_frames"]):
                self.perm[half] = not self.perm[half]
                out[a], out[b] = out[b], out[a]
                self.swap_votes[half] = 0

    def _fill(self, out: dict[str, Player | None], candidates: list[_Candidate]) -> None:
        from scipy.optimize import linear_sum_assignment

        kc = self.kc
        for half, names in PAIRS.items():
            # A slot never seen is still the tracker's to seed (confirmation_frames).
            empty = [n for n in names if out[n] is None and self.keep[n].pos is not None]
            if not empty:
                continue
            free = [c for c in candidates if c.side == half and not self._taken(c, out)]
            if not free:
                for n in empty:
                    self.keep[n].pending, self.keep[n].pending_count = None, 0
                continue
            big = 1e6
            cost = np.full((len(empty), len(free)), big)
            for i, n in enumerate(empty):
                slot = self.keep[n]
                pred = slot.predict()
                following = pred is not None and slot.missing <= int(kc["max_coast_frames"])
                for j, c in enumerate(free):
                    appearance = appearance_distance(slot.hist, c.hist)
                    known = slot.hist is not None and c.hist is not None
                    if known and appearance > float(kc["max_appearance"]):
                        continue
                    if following:
                        assert pred is not None
                        widen = slot.missing * float(kc["gate_per_frame_m"])
                        gate = min(float(kc["max_gate_m"]), float(kc["gate_m"]) + widen)
                        dist = float(np.linalg.norm(c.pos - pred))
                        if dist > gate:
                            continue
                        cost[i, j] = dist + float(kc["appearance_weight"]) * appearance
                    elif c.inside and c.height_ok:
                        # Re-seed: only from the court itself, nearest to where it was.
                        assert slot.pos is not None
                        cost[i, j] = 0.1 * float(np.linalg.norm(c.pos - slot.pos)) + appearance
            rows, cols = linear_sum_assignment(cost)
            chosen = {empty[i]: free[j] for i, j in zip(rows, cols, strict=True)
                      if cost[i, j] < big}  # fmt: skip
            for n in empty:
                slot = self.keep[n]
                c = chosen.get(n)
                if c is None:
                    slot.pending, slot.pending_count = None, 0
                    continue
                following = slot.pos is not None and slot.missing <= int(kc["max_coast_frames"])
                if not following:
                    step = float(kc["reseed_step_m"])
                    if slot.pending is not None and np.linalg.norm(c.pos - slot.pending) <= step:
                        slot.pending_count += 1
                    else:
                        slot.pending_count = 1
                    slot.pending = c.pos
                    if slot.pending_count < int(kc["reseed_frames"]):
                        continue
                p = c.player
                if not c.inside:
                    p = p.model_copy(update={"court_position_valid": False})
                out[n] = p

    def _observe(self, out: dict[str, Player | None], candidates: list[_Candidate]) -> None:
        kc = self.kc
        by_box = {tuple(c.player.bbox): c for c in candidates}
        close = {}
        for half, (a, b) in PAIRS.items():
            pa, pb = self.keep[a].predict(), self.keep[b].predict()
            close[half] = (
                pa is not None and pb is not None
                and float(np.linalg.norm(pa - pb)) < float(kc["close_m"])
            )  # fmt: skip
        alpha, beta = float(kc["alpha"]), float(kc["beta"])
        for name, slot in self.keep.items():
            half = "near" if name.startswith("near") else "far"
            if self.swap_votes[half]:
                continue  # a swap under consideration: do not learn from either pairing
            p = out[name]
            c = by_box.get(tuple(p.bbox)) if p is not None else None
            if c is None:
                slot.missing += 1
                slot.vel = slot.vel * float(kc["velocity_decay"])
                continue
            if slot.pos is None or slot.missing > int(kc["max_coast_frames"]):
                slot.pos, slot.vel = c.pos.astype(float), np.zeros(2)
            else:
                pred = slot.pos + slot.vel
                residual = c.pos - pred
                slot.pos = pred + alpha * residual
                slot.vel = slot.vel + beta * residual
            slot.missing = 0
            slot.pending, slot.pending_count = None, 0
            if c.hist is not None and not close[half]:
                slot.hist = c.hist if slot.hist is None else 0.9 * slot.hist + 0.1 * c.hist
