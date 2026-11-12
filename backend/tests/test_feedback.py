"""One passing and one failing synthetic pose per rule, plus the low-score skip."""

from __future__ import annotations

import numpy as np
import pytest

from shuttlesense.feedback.rules import (
    DEFAULTS,
    RULES,
    HitPose,
    contact_above_head,
    contact_above_shoulder,
    contact_below_waist,
    elbow_extension,
    evaluate,
    lunge_knee_bend,
    racket_arm_forward,
    rules_for,
    short_follow_through,
    stable_feet,
    wrist_below_shoulder,
)
from shuttlesense.schema import STROKE_CLASSES, ClipRecord, Frame, Hit, Player

# Standing pose, image coordinates (y down), body 200 px tall, right-handed.
BASE = {
    0: (100, 20), 5: (85, 50), 6: (115, 50), 7: (80, 85), 8: (120, 85), 9: (78, 115),
    10: (122, 115), 11: (90, 110), 12: (110, 110), 13: (90, 155), 14: (110, 155),
    15: (90, 200), 16: (110, 200),
}  # fmt: skip


def pose(changes: dict[int, tuple[float, float]] | None = None, score: float = 0.9) -> np.ndarray:
    kps = np.zeros((17, 3))
    for j, (x, y) in {**BASE, **(changes or {})}.items():
        kps[j] = x, y, score
    for j in (1, 2, 3, 4):
        kps[j] = 100, 20, score
    return kps


def hp(frames, side: str = "near", centre: int | None = None) -> HitPose:
    frames = frames if isinstance(frames, list) else [frames]
    c = len(frames) // 2 if centre is None else centre
    return HitPose(frames, c, side, "right", 200.0, dict(DEFAULTS))


OVERHEAD = {6: (115, 50), 8: (118, 15), 10: (120, -20)}  # straight arm above the head
BENT_HIGH = {8: (140, 30), 10: (110, 5)}  # wrist above the head, elbow bent
LUNGE = {12: (110, 110), 14: (140, 140), 16: (110, 170)}  # right knee bent ~80 deg


@pytest.mark.parametrize(
    ("check", "good", "bad"),
    [
        (contact_above_head, OVERHEAD, {}),
        (elbow_extension, OVERHEAD, BENT_HIGH),
        (contact_above_shoulder, {10: (120, 40)}, {}),
        (wrist_below_shoulder, {}, OVERHEAD),
        (contact_below_waist, {10: (122, 130)}, {10: (122, 90)}),
        (lunge_knee_bend, LUNGE, {}),
        (racket_arm_forward, {10: (122, 100)}, {10: (122, 130)}),
    ],
)
def test_single_frame_rules(check, good, bad) -> None:
    assert check(hp(pose(good)))[0] is True
    assert check(hp(pose(bad)))[0] is False


def test_racket_arm_forward_depends_on_side() -> None:
    # For the far player the net is down the image: a wrist below the hip reaches forward.
    assert racket_arm_forward(hp(pose({10: (122, 130)}), side="far"))[0] is True


def test_short_follow_through() -> None:
    still = [pose({10: (122, 40 + i)}) for i in range(13)]
    swing = [pose({10: (122, 40 + 40 * max(0, i - 6))}) for i in range(13)]
    assert short_follow_through(hp(still))[0] is True
    assert short_follow_through(hp(swing))[0] is False


def test_stable_feet() -> None:
    still = [pose() for _ in range(13)]
    moving = [pose({15: (90 + 15 * i, 200), 16: (110, 200)}) for i in range(13)]
    assert stable_feet(hp(still))[0] is True
    assert stable_feet(hp(moving))[0] is False


def test_low_score_joints_skip_the_rule() -> None:
    weak = pose(OVERHEAD, score=0.1)
    assert contact_above_head(hp(weak)) is None
    assert elbow_extension(hp(weak)) is None


def test_every_class_has_two_rules_and_short_tips() -> None:
    for stroke in STROKE_CLASSES:
        assert len(rules_for(stroke)) >= 2, stroke
    assert all(len(r.tip) <= 70 for r in RULES)


def test_evaluate_fills_feedback_items() -> None:
    frames = []
    for i in range(20):
        kps = pose(OVERHEAD)
        frames.append(
            Frame(frame=i, players={"near": Player(bbox=(70, -30, 60, 230), keypoints=kps)})
        )
    record = ClipRecord(clip_id="c", fps=30, width=640, height=360, num_frames=20, frames=frames)
    hit = Hit(id=0, frame=10, time_s=0.33, player="near", stroke="smash")
    items = evaluate(record, hit, dict(DEFAULTS))
    assert {i.rule for i in items} == {"contact_above_head", "elbow_extension"}
    assert all(i.passed and i.tip is None for i in items)
    hit.stroke = None
    assert evaluate(record, hit, dict(DEFAULTS)) == []


def test_doubles_skips_feedback_on_unsure_strokes() -> None:
    """T9.7: the stroke model learned from singles, so doubles coaches only on sure strokes."""
    from shuttlesense.config import with_court
    from shuttlesense.fake import load_golden
    from shuttlesense.feedback import run
    from shuttlesense.stage import StageContext

    record = load_golden("doubles")
    record.hits[1].confidence = 0.3
    run(record, StageContext(video_path=None, out_dir=None, config=with_court({}, "doubles")))
    assert record.hits[1].feedback == [] and record.hits[2].feedback
    singles = load_golden()
    singles.hits[1].confidence = 0.3
    run(singles, StageContext(video_path=None, out_dir=None, config={}))
    assert singles.hits[1].feedback  # singles is unchanged
