"""Model-independent player logic (F3/F4): court filter, stable near/far IDs, smoothing.

Pure NumPy so it is tested without rtmlib or a GPU.
"""

from __future__ import annotations

import numpy as np

from shuttlesense.schema import COURT_SIZE_M, NUM_KEYPOINTS, Player, Point


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
