"""Model-independent player logic (F3/F4): court filter, stable near/far IDs, smoothing.

Pure NumPy (plus OpenCV for the doubles shirt colours) so it is tested without rtmlib or a
GPU. Doubles (Phase 9) adds DoublesTracker: four slots, two per side.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from shuttlesense.schema import COURT_SIZE_M, NUM_KEYPOINTS, Player, PlayerId, Players, Point


def foot_point(p: Player) -> tuple[float, float]:
    x, y, w, h = p.bbox
    return x + w / 2, y + h


def centre(p: Player) -> np.ndarray:
    x, y, w, h = p.bbox
    return np.array([x + w / 2, y + h / 2])


def filter_players(
    people: list[Player],
    *,
    frame_height: int,
    homography: np.ndarray | None = None,
    margin_m: float = 1.5,
    max_players: int = 2,
    court_size: Point = COURT_SIZE_M,
) -> list[Player]:
    """Keep at most `max_players` people who are plausibly players, largest first.

    With a court homography: feet inside the court expanded by `margin_m`. Without one: feet
    in the lower 90% of the frame (drops spectators in the stands).
    """
    kept = []
    for p in people:
        fx, fy = foot_point(p)
        if homography is not None:
            from shuttlesense.court import image_to_court

            cx, cy = image_to_court(homography, np.array([[fx, fy]]))[0]
            w, length = court_size
            if not (-margin_m <= cx <= w + margin_m and -margin_m <= cy <= length + margin_m):
                continue
        elif fy < 0.1 * frame_height:
            continue
        kept.append(p)
    kept.sort(key=lambda p: p.bbox[2] * p.bbox[3], reverse=True)
    return kept[:max_players]


class PlayerTracker:
    """Keeps near/far IDs stable across frames.

    The first frame with people assigns sides by feet position; afterwards each side takes
    the detection closest to its previous box centre (greedy, cheapest pair first), so IDs
    survive players crossing near the net. A side with no detection keeps its previous box
    for up to `hold_frames` frames with its score multiplied by `hold_decay`.
    """

    def __init__(self, hold_frames: int = 5, hold_decay: float = 0.5) -> None:
        self.hold_frames = hold_frames
        self.hold_decay = hold_decay
        self.last: dict[str, Player | None] = {"near": None, "far": None}
        self.missing: dict[str, int] = {"near": 0, "far": 0}

    def update(self, people: list[Player]) -> tuple[Player | None, Player | None]:
        from shuttlesense.pose.estimator import assign_sides

        if self.last["near"] is None and self.last["far"] is None:
            near, far = assign_sides(people)
            matched = {"near": near, "far": far}
        else:
            matched = self._match(people)
        for side in ("near", "far"):
            p = matched[side]
            if p is not None:
                self.last[side], self.missing[side] = p, 0
                continue
            self.missing[side] += 1
            prev = self.last[side]
            if prev is not None and self.missing[side] <= self.hold_frames:
                matched[side] = prev.model_copy(update={"score": prev.score * self.hold_decay})
                self.last[side] = matched[side]
            else:
                self.last[side] = None
        return matched["near"], matched["far"]

    def _match(self, people: list[Player]) -> dict[str, Player | None]:
        pairs = []
        for side, prev in self.last.items():
            if prev is None:
                continue
            for j, p in enumerate(people):
                pairs.append((float(np.linalg.norm(centre(p) - centre(prev))), side, j))
        matched: dict[str, Player | None] = {"near": None, "far": None}
        used: set[int] = set()
        for _dist, side, j in sorted(pairs):
            if matched[side] is None and j not in used:
                matched[side] = people[j]
                used.add(j)
        # A side that had no previous box takes a leftover detection, if any.
        rest = [p for j, p in enumerate(people) if j not in used]
        for side in ("near", "far"):
            if matched[side] is None and self.last[side] is None and rest:
                matched[side] = rest.pop(0)
        return matched


# Doubles (Phase 9, T9.3/T9.4) ---------------------------------------------------------------

SIDE_SLOTS: dict[str, tuple[PlayerId, PlayerId]] = {
    "near": ("near_1", "near_2"),
    "far": ("far_1", "far_2"),
}
TORSO = (5, 6, 11, 12)  # COCO shoulders and hips
HIST_BINS = (8, 4)  # hue x saturation


def torso_histogram(
    frame: np.ndarray, p: Player, scale: tuple[float, float] = (1.0, 1.0)
) -> np.ndarray | None:
    """Normalised hue-saturation histogram of the shirt (shoulder-to-hip box), or None.

    `scale` maps the player's coordinates to the frame's pixels (live frames may be smaller).
    Without confident torso keypoints the middle of the bounding box is used.
    """
    import cv2

    pts = [p.keypoints[k] for k in TORSO if k < len(p.keypoints) and p.keypoints[k][2] >= 0.3]
    if len(pts) >= 3:
        xs, ys = [x for x, _, _ in pts], [y for _, y, _ in pts]
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    else:
        x, y, w, h = p.bbox
        x0, x1, y0, y1 = x + 0.25 * w, x + 0.75 * w, y + 0.2 * h, y + 0.5 * h
    sx, sy = scale
    h_img, w_img = frame.shape[:2]
    c0, c1 = int(max(0, x0 * sx)), int(min(w_img, x1 * sx))
    r0, r1 = int(max(0, y0 * sy)), int(min(h_img, y1 * sy))
    if c1 - c0 < 2 or r1 - r0 < 2:
        return None
    hsv = cv2.cvtColor(np.ascontiguousarray(frame[r0:r1, c0:c1]), cv2.COLOR_BGR2HSV)
    hist = cv2.calcHist([hsv], [0, 1], None, list(HIST_BINS), [0, 180, 0, 256]).ravel()
    total = float(hist.sum())
    return hist / total if total > 0 else None


def appearance_distance(a: np.ndarray | None, b: np.ndarray | None) -> float:
    """0 for the same colours, 1 for none in common (Bhattacharyya); 0 when unknown."""
    if a is None or b is None:
        return 0.0
    return float(1.0 - np.clip(np.sum(np.sqrt(a * b)), 0.0, 1.0))


class DoublesTracker:
    """Four player slots, two per side, kept stable across frames.

    Each detection goes to the side of the net its feet are on: the court plane with a
    homography, else above or below an image line learned on the first frame with four
    people. Within a side, both ways of pairing its two slots with its two detections are
    tried and the cheaper kept: court distance (meters; tenths of the frame height without a
    homography) plus `appearance_weight` times the shirt-colour distance. When partners stand
    within `close_m` of each other, position cannot tell them apart and appearance alone
    decides. A slot never crosses the net. A missing slot keeps its last box for
    `hold_frames` frames, as in PlayerTracker. A side's slots start in image order: _1 is the
    left one.
    """

    def __init__(
        self,
        hold_frames: int = 5,
        hold_decay: float = 0.5,
        *,
        appearance_weight: float = 2.0,
        close_m: float = 0.6,
        history: float = 0.9,
        court_size: Point = COURT_SIZE_M,
    ) -> None:
        self.hold_frames = hold_frames
        self.hold_decay = hold_decay
        self.appearance_weight = appearance_weight
        self.close_m = close_m
        self.history = history
        self.net_y = court_size[1] / 2
        self.split_y: float | None = None  # image y between the sides, without a homography
        slots = [s for pair in SIDE_SLOTS.values() for s in pair]
        self.last: dict[PlayerId, Player | None] = dict.fromkeys(slots)
        self.pos: dict[PlayerId, np.ndarray | None] = dict.fromkeys(slots)
        self.hist: dict[PlayerId, np.ndarray | None] = dict.fromkeys(slots)
        self.missing: dict[PlayerId, int] = dict.fromkeys(slots, 0)

    def update(
        self,
        people: list[Player],
        *,
        frame_height: float,
        homography: np.ndarray | None = None,
        frame: np.ndarray | None = None,
        image_scale: tuple[float, float] = (1.0, 1.0),
    ) -> dict[PlayerId, Player | None]:
        unit = 1.0 if homography is not None else max(frame_height, 1.0) / 10
        located = [(p, self._locate(p, homography)) for p in people]
        sides = self._split(located, frame_height, homography is not None)
        out: dict[PlayerId, Player | None] = {}
        for side, slots in SIDE_SLOTS.items():
            dets = sorted(sides[side], key=lambda d: d[0].bbox[2] * d[0].bbox[3], reverse=True)
            dets = dets[:2]
            hists = [
                torso_histogram(frame, p, image_scale) if frame is not None else None
                for p, _ in dets
            ]
            assigned = self._assign(slots, dets, hists, unit)
            for slot in slots:
                j = assigned.get(slot)
                if j is not None:
                    p, xy = dets[j]
                    self.last[slot], self.pos[slot], self.missing[slot] = p, xy, 0
                    self._remember(slot, hists[j])
                    out[slot] = p
                    continue
                self.missing[slot] += 1
                prev = self.last[slot]
                if prev is not None and self.missing[slot] <= self.hold_frames:
                    out[slot] = prev.model_copy(update={"score": prev.score * self.hold_decay})
                    self.last[slot] = out[slot]
                else:
                    out[slot] = self.last[slot] = None
                    self.pos[slot] = None
        return out

    def _remember(self, slot: PlayerId, hist: np.ndarray | None) -> None:
        if hist is None:
            return
        old = self.hist[slot]
        self.hist[slot] = hist if old is None else self.history * old + (1 - self.history) * hist

    @staticmethod
    def _locate(p: Player, homography: np.ndarray | None) -> np.ndarray:
        fx, fy = foot_point(p)
        if homography is None:
            return np.array([fx, fy])
        from shuttlesense.court import image_to_court

        return image_to_court(homography, np.array([[fx, fy]]))[0]

    def _split(
        self, located: list[tuple[Player, np.ndarray]], frame_height: float, on_court: bool
    ) -> dict[str, list[tuple[Player, np.ndarray]]]:
        sides: dict[str, list[tuple[Player, np.ndarray]]] = {"near": [], "far": []}
        if on_court:
            for p, xy in located:
                sides["near" if xy[1] < self.net_y else "far"].append((p, xy))
            return sides
        feet = sorted(float(xy[1]) for _, xy in located)
        if self.split_y is None and len(feet) >= 4:
            self.split_y = (feet[-2] + feet[-3]) / 2  # between the 2nd and 3rd lowest feet
        split = self.split_y if self.split_y is not None else frame_height / 2
        for p, xy in located:  # image y grows downwards, towards the camera (near side)
            sides["near" if xy[1] > split else "far"].append((p, xy))
        return sides

    def _assign(
        self,
        slots: tuple[PlayerId, PlayerId],
        dets: list[tuple[Player, np.ndarray]],
        hists: list[np.ndarray | None],
        unit: float,
    ) -> dict[PlayerId, int]:
        if not dets:
            return {}
        a, b = slots
        if self.pos[a] is None and self.pos[b] is None:  # first sight: left to right
            order = sorted(range(len(dets)), key=lambda j: centre(dets[j][0])[0])
            return {slot: j for slot, j in zip(slots, order, strict=False)}
        pa, pb = self.pos[a], self.pos[b]
        close = (
            pa is not None
            and pb is not None
            and float(np.linalg.norm(pa - pb)) / unit < self.close_m
        )

        def cost(slot: PlayerId, j: int) -> float:
            appearance = self.appearance_weight * appearance_distance(self.hist[slot], hists[j])
            prev = self.pos[slot]
            if prev is None:
                return appearance + 1.0  # back from a gap: a seen slot keeps priority
            if close and self.hist[slot] is not None and hists[j] is not None:
                return appearance
            return float(np.linalg.norm(dets[j][1] - prev)) / unit + appearance

        options = [{a: 0}, {b: 0}] if len(dets) == 1 else [{a: 0, b: 1}, {a: 1, b: 0}]
        return min(options, key=lambda o: sum(cost(s, j) for s, j in o.items()))


def make_tracker(cfg: dict[str, Any], court: str) -> PlayerTracker | DoublesTracker:
    """The tracker for a singles or doubles match, from stages.pose config."""
    hold = int(cfg.get("hold_frames", 5))
    if court != "doubles":
        return PlayerTracker(hold_frames=hold)
    return DoublesTracker(
        hold_frames=hold,
        appearance_weight=float(cfg.get("appearance_weight", 2.0)),
        close_m=float(cfg.get("partners_close_m", 0.6)),
    )


def track_players(
    tracker: PlayerTracker | DoublesTracker,
    people: list[Player],
    *,
    frame_height: float,
    homography: np.ndarray | None = None,
    frame: np.ndarray | None = None,
    image_scale: tuple[float, float] = (1.0, 1.0),
) -> Players:
    """One frame's players from either tracker."""
    if isinstance(tracker, DoublesTracker):
        slots = tracker.update(people, frame_height=frame_height, homography=homography,
                               frame=frame, image_scale=image_scale)  # fmt: skip
        return Players(near=slots["near_1"], near_2=slots["near_2"], far=slots["far_1"],
                       far_2=slots["far_2"])  # fmt: skip
    near, far = tracker.update(people)
    return Players(near=near, far=far)


def smooth_keypoints(
    sequence: list[list[tuple[float, float, float]] | None],
    window: int = 5,
    min_score: float = 0.3,
) -> list[list[tuple[float, float, float]] | None]:
    """Centred moving average per joint over `window` frames.

    Only joints with score >= min_score contribute, and frames where the player is missing
    (None) break the average, so nothing is smoothed across a gap. Low-score joints are
    returned unchanged.
    """
    n = len(sequence)
    if window <= 1 or n == 0:
        return list(sequence)
    half = window // 2
    out: list[list[tuple[float, float, float]] | None] = []
    for i, kps in enumerate(sequence):
        if kps is None:
            out.append(None)
            continue
        lo = i
        while lo > i - half and lo > 0 and sequence[lo - 1] is not None:
            lo -= 1
        hi = i
        while hi < i + half and hi < n - 1 and sequence[hi + 1] is not None:
            hi += 1
        arr = np.array([sequence[k] for k in range(lo, hi + 1)], dtype=float)  # (T, 17, 3)
        smoothed = []
        for j in range(min(NUM_KEYPOINTS, len(kps))):
            x, y, s = kps[j]
            good = arr[:, j, 2] >= min_score
            if s >= min_score and good.any():
                x, y = arr[good, j, 0].mean(), arr[good, j, 1].mean()
            smoothed.append((round(float(x), 1), round(float(y), 1), float(s)))
        out.append(smoothed)
    return out


def bbox_from_keypoints(
    keypoints: np.ndarray, scores: np.ndarray, min_score: float = 0.3, pad: float = 0.1
) -> tuple[float, float, float, float] | None:
    """(x, y, w, h) around the confident joints, padded by `pad` of the size on each side."""
    pts = keypoints[scores >= min_score]
    if len(pts) < 3:
        return None
    x0, y0 = pts.min(axis=0)
    x1, y1 = pts.max(axis=0)
    w, h = x1 - x0, y1 - y0
    return (float(x0 - pad * w), float(y0 - pad * h), float(w * (1 + 2 * pad)),
            float(h * (1 + 2 * pad)))  # fmt: skip
