"""Form feedback rules from pose angles (F8, FR-8).

Each stroke class has at least 2 rules (see docs/FEEDBACK_RULES.md). A rule looks at the
hitter's keypoints around the hit frame and returns (passed, measured value), or None
when the joints it needs are not confident (no tip is better than a wrong tip).
Thresholds come from configs/pipeline.yaml stages.feedback.
Feedback is heuristic guidance, not professional coaching.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

import numpy as np

from shuttlesense.schema import ClipRecord, FeedbackItem, Hit, StrokeClass
from shuttlesense.stage import StageContext

NOSE = 0
SHOULDER, ELBOW, WRIST = {"left": 5, "right": 6}, {"left": 7, "right": 8}, {"left": 9, "right": 10}
HIP, KNEE, ANKLE = {"left": 11, "right": 12}, {"left": 13, "right": 14}, {"left": 15, "right": 16}

DEFAULTS: dict[str, float] = {
    "min_keypoint_score": 0.3,
    "window_frames": 2,  # evaluate the hit frame +- this many frames
    "elbow_extension_deg": 150,
    "lunge_knee_deg": 140,
    "drop_follow_through": 0.6,  # wrist travel in the next 5 frames, in bbox heights
    "serve_feet_motion": 0.1,  # ankle travel in the 5 frames before contact, in bbox heights
}


def joint_angle(a: np.ndarray, b: np.ndarray, c: np.ndarray) -> float:
    """Angle ABC in degrees, e.g. shoulder-elbow-wrist for the elbow angle."""
    ba, bc = a - b, c - b
    cos = float(np.dot(ba, bc) / (np.linalg.norm(ba) * np.linalg.norm(bc) + 1e-9))
    return float(np.degrees(np.arccos(np.clip(cos, -1.0, 1.0))))


@dataclass
class HitPose:
    """The hitter's keypoints around one hit, with helpers that respect joint scores."""

    frames: list[np.ndarray | None]  # (17, 3) per frame from hit - before to hit + after
    centre: int  # index of the hit frame in `frames`
    side: str  # "near" or "far"
    arm: str  # racket arm: "left" or "right"
    bbox_height: float
    cfg: dict[str, float]

    def kp(self, offset: int, joint: int) -> np.ndarray | None:
        i = self.centre + offset
        if not 0 <= i < len(self.frames) or self.frames[i] is None:
            return None
        k = self.frames[i][joint]
        return k[:2] if k[2] >= self.cfg["min_keypoint_score"] else None

    def around_hit(self) -> range:
        w = int(self.cfg["window_frames"])
        return range(-w, w + 1)

    @property
    def towards_net(self) -> float:
        """Image y direction pointing at the net: up for the near player, down for far."""
        return -1.0 if self.side == "near" else 1.0


Check = Callable[[HitPose], tuple[bool, float] | None]


@dataclass(frozen=True)
class Rule:
    name: str
    classes: tuple[StrokeClass, ...]
    check: Check
    tip: str


def _best(values: list[float | None], higher_is_better: bool = True) -> float | None:
    present = [v for v in values if v is not None]
    if not present:
        return None
    return float(max(present) if higher_is_better else min(present))


def contact_above_head(pose: HitPose) -> tuple[bool, float] | None:
    """Wrist above the nose (image y smaller). Value: margin in bbox heights."""
    margin = _best(
        [
            (nose[1] - wrist[1]) / pose.bbox_height
            for o in pose.around_hit()
            if (wrist := pose.kp(o, WRIST[pose.arm])) is not None
            and (nose := pose.kp(o, NOSE)) is not None
        ]
    )
    return None if margin is None else (margin > 0, margin)


def contact_above_shoulder(pose: HitPose) -> tuple[bool, float] | None:
    margin = _best(
        [
            (shoulder[1] - wrist[1]) / pose.bbox_height
            for o in pose.around_hit()
            if (wrist := pose.kp(o, WRIST[pose.arm])) is not None
            and (shoulder := pose.kp(o, SHOULDER[pose.arm])) is not None
        ]
    )
    return None if margin is None else (margin > 0, margin)


def wrist_below_shoulder(pose: HitPose) -> tuple[bool, float] | None:
    result = contact_above_shoulder(pose)
    return None if result is None else (result[1] < 0, -result[1])


def contact_below_waist(pose: HitPose) -> tuple[bool, float] | None:
    """Singles low-serve rule: wrist below the hip at contact."""
    margin = _best(
        [
            (wrist[1] - hip[1]) / pose.bbox_height
            for o in pose.around_hit()
            if (wrist := pose.kp(o, WRIST[pose.arm])) is not None
            and (hip := pose.kp(o, HIP[pose.arm])) is not None
        ]
    )
    return None if margin is None else (margin > 0, margin)


def elbow_extension(pose: HitPose) -> tuple[bool, float] | None:
    """Shoulder-elbow-wrist angle of the racket arm at contact (straighter is better)."""
    angle = _best(
        [
            joint_angle(s, e, w)
            for o in pose.around_hit()
            if (s := pose.kp(o, SHOULDER[pose.arm])) is not None
            and (e := pose.kp(o, ELBOW[pose.arm])) is not None
            and (w := pose.kp(o, WRIST[pose.arm])) is not None
        ]
    )
    return None if angle is None else (angle >= pose.cfg["elbow_extension_deg"], angle)


def lunge_knee_bend(pose: HitPose) -> tuple[bool, float] | None:
    """Smallest hip-knee-ankle angle of either leg (a bent lunge knee is good)."""
    angle = _best(
        [
            joint_angle(h, k, a)
            for o in pose.around_hit()
            for leg in ("left", "right")
            if (h := pose.kp(o, HIP[leg])) is not None
            and (k := pose.kp(o, KNEE[leg])) is not None
            and (a := pose.kp(o, ANKLE[leg])) is not None
        ],
        higher_is_better=False,
    )
    return None if angle is None else (angle <= pose.cfg["lunge_knee_deg"], angle)


def racket_arm_forward(pose: HitPose) -> tuple[bool, float] | None:
    """Wrist reaches past the hip towards the net. Value: reach in bbox heights."""
    reach = _best(
        [
            (wrist[1] - hip[1]) * pose.towards_net / pose.bbox_height
            for o in pose.around_hit()
            if (wrist := pose.kp(o, WRIST[pose.arm])) is not None
            and (hip := pose.kp(o, HIP[pose.arm])) is not None
        ]
    )
    return None if reach is None else (reach > 0, reach)


def _travel(pose: HitPose, joint: int, offsets: range) -> float | None:
    pts = [p for o in offsets if (p := pose.kp(o, joint)) is not None]
    if len(pts) < 2:
        return None
    return float(sum(np.linalg.norm(b - a) for a, b in zip(pts, pts[1:], strict=False)))


def short_follow_through(pose: HitPose) -> tuple[bool, float] | None:
    """A drop is a gentle stroke: the wrist travels little in the 5 frames after contact."""
    travel = _travel(pose, WRIST[pose.arm], range(0, 6))
    if travel is None:
        return None
    value = travel / pose.bbox_height
    return value <= pose.cfg["drop_follow_through"], value


def stable_feet(pose: HitPose) -> tuple[bool, float] | None:
    """Both feet stay put in the 5 frames before the serve (no foot movement rule)."""
    moves = [_travel(pose, ANKLE[leg], range(-5, 1)) for leg in ("left", "right")]
    if any(m is None for m in moves):
        return None
    value = max(moves) / pose.bbox_height
    return value <= pose.cfg["serve_feet_motion"], value


RULES: tuple[Rule, ...] = (
    Rule("contact_above_head", ("smash", "clear"), contact_above_head,
         "Meet the shuttle higher, above your head"),
    Rule("elbow_extension", ("smash", "clear"), elbow_extension,
         "Straighten your hitting arm more at contact"),
    Rule("contact_above_shoulder", ("drop",), contact_above_shoulder,
         "Take the drop earlier, above shoulder height"),
    Rule("short_follow_through", ("drop",), short_follow_through,
         "Shorten the follow-through to keep the drop soft"),
    Rule("lunge_knee_bend", ("net_shot", "lift"), lunge_knee_bend,
         "Bend your front knee more in the lunge"),
    Rule("racket_arm_forward", ("net_shot",), racket_arm_forward,
         "Reach forward with the racket arm toward the net"),
    Rule("wrist_below_shoulder", ("lift",), wrist_below_shoulder,
         "Get under the shuttle: contact below the shoulder"),
    Rule("contact_below_waist", ("serve",), contact_below_waist,
         "Serve from below the waist (service rule)"),
    Rule("stable_feet", ("serve",), stable_feet,
         "Keep both feet still until the shuttle is struck"),
)  # fmt: skip


def rules_for(stroke: StrokeClass) -> list[Rule]:
    return [r for r in RULES if stroke in r.classes]


def hit_pose(record: ClipRecord, hit: Hit, cfg: dict[str, float], span: int = 6) -> HitPose | None:
    """Keypoints of the hitter from hit - span to hit + span; None if they are missing."""
    frames: list[np.ndarray | None] = []
    heights = []
    for i in range(hit.frame - span, hit.frame + span + 1):
        p = (
            getattr(record.frames[i].players, hit.player_attr)
            if 0 <= i < len(record.frames)
            else None
        )
        if p is None or len(p.keypoints) < 17:
            frames.append(None)
            continue
        frames.append(np.asarray(p.keypoints, dtype=float))
        heights.append(p.bbox[3])
    centre = frames[span]
    if centre is None or not heights:
        return None
    arm = _racket_arm(record, hit, centre, cfg["min_keypoint_score"])
    return HitPose(frames, span, hit.player, arm, float(np.median(heights)) or 1.0, cfg)


def _racket_arm(record: ClipRecord, hit: Hit, kps: np.ndarray, min_score: float) -> str:
    """The wrist closest to the shuttle at the hit, else the more confident wrist."""
    s = record.frames[hit.frame].shuttle
    left, right = kps[WRIST["left"]], kps[WRIST["right"]]
    if s is not None and s.visible and min(left[2], right[2]) >= min_score:
        point = np.array([s.x, s.y])
        d_left = np.linalg.norm(left[:2] - point)
        d_right = np.linalg.norm(right[:2] - point)
        return "left" if d_left < d_right else "right"
    return "left" if left[2] > right[2] else "right"


def evaluate(record: ClipRecord, hit: Hit, cfg: dict[str, Any]) -> list[FeedbackItem]:
    """One FeedbackItem per applicable rule, with the tip only when the rule fails.

    A stroke below `min_stroke_confidence` gets no feedback: the rules depend on the class.
    """
    if hit.stroke is None:
        return []
    gate = float(cfg.get("min_stroke_confidence", 0.0))
    if hit.confidence is not None and hit.confidence < gate:
        return []
    pose = hit_pose(record, hit, cfg)
    if pose is None:
        return []
    items = []
    for rule in rules_for(hit.stroke):
        result = rule.check(pose)
        if result is None:
            continue
        passed, value = result
        items.append(FeedbackItem(rule=rule.name, passed=bool(passed),
                                  tip=None if passed else rule.tip,
                                  value=round(float(value), 3)))  # fmt: skip
    return items


def run(record: ClipRecord, ctx: StageContext) -> ClipRecord:
    """Fill hits[].feedback for every hit with a stroke class."""
    from shuttlesense.config import court_type

    cfg = {**DEFAULTS, **ctx.stage_config("feedback")}
    if court_type(ctx.config) == "doubles":
        # The stroke model learned from singles (T9.7): only coach on strokes it is sure of.
        cfg["min_stroke_confidence"] = cfg.get("min_stroke_confidence_doubles", 0.5)
    for hit in record.hits:
        hit.feedback = evaluate(record, hit, cfg)
    ctx.progress(1.0)
    return record
