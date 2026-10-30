"""Regenerate golden_record.json: python tests/fixtures/make_golden_record.py (task T1.10).

A hand-shaped 60-frame, 1280x720 @ 30 fps rally with plausible (not real) values: a serve by
the near player, a clear by the far player and a smash by the near player that lands in.
The same file is copied to app/test/fixtures/ for the Flutter tests.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import numpy as np

from shuttlesense.analytics.export import build_summary
from shuttlesense.court import compute_homography, image_to_court
from shuttlesense.referee import build_events, derive_from_rallies
from shuttlesense.schema import (
    ClipRecord,
    Court,
    CourtPositions,
    FeedbackItem,
    Frame,
    Hit,
    Landing,
    Player,
    Players,
    Rally,
    Score,
    ScorePair,
    Shuttle,
)

HERE = Path(__file__).resolve().parent
APP_FIXTURE = HERE.parents[2] / "app" / "test" / "fixtures" / "golden_record.json"

FPS = 30.0
WIDTH, HEIGHT = 1280, 720
NUM_FRAMES = 60
CORNERS = ((212.0, 650.0), (1068.0, 650.0), (880.0, 210.0), (400.0, 210.0))

# Standing skeleton in bbox-relative coordinates (COCO-17 order).
SKELETON = [
    (0.50, 0.06), (0.47, 0.04), (0.53, 0.04), (0.44, 0.05), (0.56, 0.05),
    (0.38, 0.20), (0.62, 0.20), (0.30, 0.35), (0.70, 0.35), (0.25, 0.48),
    (0.78, 0.30), (0.42, 0.52), (0.58, 0.52), (0.40, 0.74), (0.60, 0.74),
    (0.38, 0.97), (0.62, 0.97),
]  # fmt: skip

# (frame, player, stroke, confidence, speed_kmh, feedback)
HITS = [
    (5, "near", "serve", 0.91, 62.0, [("serve_contact_below_waist", True, None)]),
    (25, "far", "clear", 0.78, 118.0, [
        ("clear_contact_above_head", True, None),
        ("clear_arm_extension", False, "Reach higher: straighten your arm at contact"),
    ]),
    (45, "near", "smash", 0.86, 241.0, [
        ("smash_contact_above_head", True, None),
        ("smash_elbow_angle", False, "Fully extend your elbow when you hit the smash"),
    ]),
]  # fmt: skip


def player(cx: float, foot_y: float, height: float, score: float) -> Player:
    w = height * 0.45
    x, y = cx - w / 2, foot_y - height
    kps = [(round(x + u * w, 1), round(y + v * height, 1), 0.9) for u, v in SKELETON]
    return Player(bbox=(round(x, 1), round(y, 1), round(w, 1), round(height, 1)),
                  keypoints=kps, score=score)  # fmt: skip


def shuttle_xy(f: int) -> tuple[float, float]:
    """Arc from hitter to hitter between hit frames; falls to the floor after the last hit."""
    keys = [(5, (700.0, 470.0)), (25, (560.0, 150.0)), (45, (690.0, 380.0)), (59, (600.0, 330.0))]
    if f <= keys[0][0]:
        return keys[0][1]
    for (f0, (x0, y0)), (f1, (x1, y1)) in zip(keys, keys[1:], strict=False):
        if f0 <= f <= f1:
            t = (f - f0) / (f1 - f0)
            arc = -160.0 * 4 * t * (1 - t)
            return x0 + (x1 - x0) * t, y0 + (y1 - y0) * t + arc
    return keys[-1][1]


def build() -> ClipRecord:
    h = compute_homography(CORNERS)
    frames, prev = [], None
    for f in range(NUM_FRAMES):
        near = player(640 + 60 * np.sin(f / 12), 640.0, 260.0, 0.94)
        far = player(620 - 40 * np.sin(f / 10), 250.0, 120.0, 0.88)
        visible = f not in (31, 32)  # a short gap, as TrackNetV3 produces
        sx, sy = shuttle_xy(f)
        feet = np.array([[near.bbox[0] + near.bbox[2] / 2, 640.0],
                         [far.bbox[0] + far.bbox[2] / 2, 250.0], [sx, sy]])  # fmt: skip
        court = image_to_court(h, feet)
        speed = None
        if visible and prev is not None:
            speed = round(float(np.hypot(*(court[2] - prev))) * FPS * 3.6, 1)
        prev = court[2] if visible else None
        frames.append(
            Frame(
                frame=f,
                shuttle=Shuttle(x=round(sx, 1), y=round(sy, 1), visible=1)
                if visible
                else Shuttle(),
                players=Players(near=near, far=far),
                court_positions=CourtPositions(
                    near=tuple(round(float(v), 2) for v in court[0]),
                    far=tuple(round(float(v), 2) for v in court[1]),
                    shuttle=tuple(round(float(v), 2) for v in court[2]) if visible else None,
                ),
                shuttle_speed_kmh=speed if speed is None else min(speed, 300.0),
                rally_state="in_play" if f <= 55 else "between_rallies",
            )
        )
    hits = [
        Hit(
            id=i,
            frame=f,
            time_s=round(f / FPS, 3),
            player=side,
            stroke=stroke,
            confidence=conf,
            class_probs=_probs(stroke, conf),
            speed_kmh=speed,
            feedback=[FeedbackItem(rule=r, passed=p, tip=t) for r, p, t in fb],
            rally_index=0,
        )
        for i, (f, side, stroke, conf, speed, fb) in enumerate(HITS)
    ]
    record = ClipRecord(
        clip_id="golden",
        source_name="golden.mp4",
        fps=FPS,
        width=WIDTH,
        height=HEIGHT,
        num_frames=NUM_FRAMES,
        court=Court(corners_px=CORNERS, homography=np.round(h, 6).tolist()),
        frames=frames,
        hits=hits,
        rallies=[
            Rally(
                index=0,
                start_frame=0,
                end_frame=55,
                stroke_count=len(hits),
                landing=Landing(x_m=1.9, y_m=10.2, in_court=True, confidence=0.92),
                winner="near",
                score_after=ScorePair(near=1, far=0),
            )
        ],
        score=Score(near=1, far=0),
    )
    record.line_calls = derive_from_rallies(record)
    landing = record.rallies[0].landing
    landing.confidence = record.line_calls[0].confidence
    record.rally_events = build_events(record)
    record.summary = build_summary(record)
    return record


def _probs(stroke: str, conf: float) -> dict[str, float]:
    from shuttlesense.schema import STROKE_CLASSES

    rest = round((1 - conf) / (len(STROKE_CLASSES) - 1), 4)
    return {c: (conf if c == stroke else rest) for c in STROKE_CLASSES}


def main() -> None:
    data = build().model_dump(mode="json")
    text = json.dumps(data, indent=1) + "\n"
    (HERE / "golden_record.json").write_text(text, encoding="utf-8", newline="\n")
    APP_FIXTURE.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(HERE / "golden_record.json", APP_FIXTURE)
    print(f"wrote {HERE / 'golden_record.json'} and {APP_FIXTURE}")


if __name__ == "__main__":
    main()
