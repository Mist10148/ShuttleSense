"""Synthetic rallies with known hits and landings (fake live source and parity tests).

Each rally is a serve and a few shots between the players' wrists, a last shot to a planned
landing point, the shuttle resting there, then a pause with the shuttle out of sight. The
values are plausible, not real: they exist so CI can drive the live path end to end without
a GPU, weights or a camera, and so offline and live results can be compared exactly.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from shuttlesense.schema import ClipRecord, Court, Frame, Player, Players, Shuttle, StrokeClass

WIDTH, HEIGHT, FPS = 1280, 720, 30.0
CORNERS = ((212.0, 650.0), (1068.0, 650.0), (880.0, 210.0), (400.0, 210.0))

# Standing skeleton in bbox-relative coordinates (COCO-17); wrists are placed separately.
_SKELETON = [
    (0.50, 0.06), (0.47, 0.04), (0.53, 0.04), (0.44, 0.05), (0.56, 0.05),
    (0.38, 0.20), (0.62, 0.20), (0.30, 0.35), (0.70, 0.35), (0.25, 0.48),
    (0.78, 0.30), (0.42, 0.52), (0.58, 0.52), (0.40, 0.74), (0.60, 0.74),
    (0.38, 0.97), (0.62, 0.97),
]  # fmt: skip


@dataclass(frozen=True)
class PlannedRally:
    server: str  # "near" or "far"
    shots: int  # hits including the serve
    landing_m: tuple[float, float]
    strokes: tuple[StrokeClass, ...] = ()


# In on the far half, out past the near sideline, and just inside the far sideline.
DEFAULT_PLAN = (
    PlannedRally("near", 3, (2.0, 10.0), ("serve", "clear", "smash")),
    PlannedRally("near", 4, (5.75, 3.0), ("serve", "lift", "clear", "drop")),
    PlannedRally("far", 3, (5.15, 10.5), ("serve", "clear", "smash")),
)

SHOT_FRAMES = 18  # flight time between hits
REST_FRAMES = 26  # shuttle lying on the floor after landing
PAUSE_FRAMES = 40  # shuttle out of sight between rallies
LEAD_FRAMES = 6  # play before the first serve (players visible, no shuttle)


def _homography() -> np.ndarray:
    from shuttlesense.court import compute_homography

    return compute_homography(CORNERS)


def _player(foot: np.ndarray, height: float, wrist: np.ndarray) -> Player:
    w = height * 0.45
    x, y = foot[0] - w / 2, foot[1] - height
    kps = [(x + u * w, y + v * height, 0.9) for u, v in _SKELETON]
    kps[9] = kps[10] = (float(wrist[0]), float(wrist[1]), 0.9)
    return Player(bbox=(x, y, w, height), keypoints=[tuple(map(float, k)) for k in kps], score=0.9)


def synthetic_record(plan: tuple[PlannedRally, ...] = DEFAULT_PLAN) -> tuple[ClipRecord, dict]:
    """(record with shuttle and players per frame, truth) for the planned rallies.

    truth holds the planned hit frames with their players and strokes, and the landing frame
    of each rally.
    """
    from shuttlesense.court import court_to_image

    h = _homography()
    feet_m = {"near": np.array([[2.6, 2.0]]), "far": np.array([[2.6, 11.4]])}
    feet_px = {side: court_to_image(h, m)[0] for side, m in feet_m.items()}
    heights = {"near": 260.0, "far": 120.0}
    wrist_px = {s: feet_px[s] + np.array([0.3 * heights[s], -0.8 * heights[s]]) for s in feet_px}

    track: list[np.ndarray | None] = [None] * LEAD_FRAMES
    truth: dict = {"hits": [], "landings": []}
    for rally in plan:
        side = rally.server
        start = len(track)
        # Toss: the shuttle drops into the server's wrist, so the serve is a direction change.
        for k in range(3, 0, -1):
            track.append(wrist_px[side] + np.array([0.0, -4.0 * k]))
        for shot in range(rally.shots):
            frame = len(track)
            stroke = rally.strokes[shot] if shot < len(rally.strokes) else None
            truth["hits"].append((frame, side, stroke))
            last = shot == rally.shots - 1
            other = "far" if side == "near" else "near"
            end = court_to_image(h, np.array([rally.landing_m]))[0] if last else wrist_px[other]
            begin = wrist_px[side]
            for t in np.linspace(0, 1, SHOT_FRAMES, endpoint=False):
                arc = -120.0 * 4 * t * (1 - t)
                track.append(begin + (end - begin) * t + np.array([0.0, arc]))
            side = other
        landing = len(track)
        truth["landings"].append(landing)
        rest = court_to_image(h, np.array([rally.landing_m]))[0]
        track.extend([rest] * REST_FRAMES)
        track.extend([None] * PAUSE_FRAMES)
        truth.setdefault("starts", []).append(start)

    frames = []
    for i, pos in enumerate(track):
        players = Players(
            near=_player(feet_px["near"], heights["near"], wrist_px["near"]),
            far=_player(feet_px["far"], heights["far"], wrist_px["far"]),
        )
        shuttle = (
            Shuttle()
            if pos is None
            else Shuttle(x=round(float(pos[0]), 2), y=round(float(pos[1]), 2), visible=1)
        )
        frames.append(Frame(frame=i, shuttle=shuttle, players=players))
    record = ClipRecord(
        clip_id="synthetic",
        fps=FPS,
        width=WIDTH,
        height=HEIGHT,
        num_frames=len(frames),
        court=Court(corners_px=CORNERS, homography=h.tolist()),
        frames=frames,
    )
    return record, truth


def planned_strokes(truth: dict) -> dict[int, StrokeClass | None]:
    """Hit frame -> planned stroke class."""
    return {frame: stroke for frame, _side, stroke in truth["hits"]}
