"""Rule-based form feedback per stroke (F8) and session coaching notes (F21)."""

from shuttlesense.feedback.patterns import build_coaching
from shuttlesense.feedback.rules import RULES, Rule, evaluate, joint_angle, rules_for, run

__all__ = ["RULES", "Rule", "build_coaching", "evaluate", "joint_angle", "rules_for", "run"]
