"""Session coaching notes (F21, FR-21): patterns across all strokes of a clip.

Per-stroke tips (rules.py) say what went wrong on one hit; a note says what keeps going
wrong, e.g. "Bent hitting arm at contact on 3 of 5 smashes". Notes are a pure function of
the clip record and the thresholds in configs/pipeline.yaml stages.feedback.patterns, so
the same record always gives the same notes. Heuristic guidance, not professional coaching.
"""

from __future__ import annotations

from collections import defaultdict
from typing import Any

from shuttlesense.schema import ClipRecord, Coaching, Hit, Moment, SessionNote

PATTERN_DEFAULTS: dict[str, Any] = {
    "min_count": 2,  # a pattern needs at least this many faulty strokes
    "min_rate": 0.5,  # ... and this share of the strokes the rule was checked on
    "top_fixes": 3,
    "max_moments": 5,  # moments listed per note
    "severity": {  # weight per rule; service faults lose the point outright
        "contact_below_waist": 1.5,
        "stable_feet": 1.5,
        "shots_out": 1.5,
    },
}

# What a failed rule looks like, phrased as the fault ("... on 3 of 5 smashes").
FAULTS: dict[str, str] = {
    "contact_above_head": "Contact below head height",
    "elbow_extension": "Bent hitting arm at contact",
    "contact_above_shoulder": "Drop taken below the shoulder",
    "short_follow_through": "Long follow-through on the drop",
    "lunge_knee_bend": "Shallow lunge, front knee too straight",
    "racket_arm_forward": "Racket arm not reaching toward the net",
    "wrist_below_shoulder": "Lift contact above the shoulder",
    "contact_below_waist": "Serve contact above the waist",
    "stable_feet": "Feet moving during the serve",
}

PLURALS = {
    "smash": "smashes",
    "clear": "clears",
    "drop": "drops",
    "net_shot": "net shots",
    "lift": "lifts",
    "serve": "serves",
}

SIDE = {
    "near": "Near player",
    "far": "Far player",
    "near_1": "Near player 1",
    "near_2": "Near player 2",
    "far_1": "Far player 1",
    "far_2": "Far player 2",
}
PAIR = {"near": "Near pair", "far": "Far pair"}


def pattern_config(feedback_cfg: dict[str, Any] | None) -> dict[str, Any]:
    cfg = {**PATTERN_DEFAULTS, **((feedback_cfg or {}).get("patterns") or {})}
    cfg["severity"] = {**PATTERN_DEFAULTS["severity"], **(cfg.get("severity") or {})}
    return cfg


def _strokes_phrase(strokes: list[str]) -> str:
    names = [PLURALS.get(s, s) for s in strokes]
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def _moments(hits: list[Hit], limit: int) -> list[Moment]:
    return [Moment(frame=h.frame, time_s=h.time_s, hit_id=h.id) for h in hits[:limit]]


def form_notes(record: ClipRecord, cfg: dict[str, Any]) -> list[SessionNote]:
    """One note per player and rule that failed often enough."""
    # In doubles a note is about the partner who hit (the side when the hitter is unknown).
    checked: dict[tuple[str, str], list[Hit]] = defaultdict(list)
    failed: dict[tuple[str, str], list[Hit]] = defaultdict(list)
    for hit in record.hits:
        who = hit.hitter or hit.player
        for item in hit.feedback:
            checked[(who, item.rule)].append(hit)
            if not item.passed:
                failed[(who, item.rule)].append(hit)
    notes = []
    for (side, rule), bad in sorted(failed.items()):
        total = len(checked[(side, rule)])
        if len(bad) < cfg["min_count"] or len(bad) / total < cfg["min_rate"]:
            continue
        strokes = sorted({h.stroke for h in checked[(side, rule)] if h.stroke})
        fault = FAULTS.get(rule, rule.replace("_", " ").capitalize() + " missed")
        notes.append(
            SessionNote(
                id=f"{rule}:{side}",
                rule=rule,
                player=side,
                stroke=strokes[0] if len(strokes) == 1 else None,
                text=f"{SIDE[side]}: {fault} on {len(bad)} of {total} "
                f"{_strokes_phrase(strokes) if strokes else 'strokes'}",
                count=len(bad),
                total=total,
                severity=float(cfg["severity"].get(rule, 1.0)),
                moments=_moments(bad, int(cfg["max_moments"])),
            )
        )
    return notes


def out_notes(record: ClipRecord, cfg: dict[str, Any]) -> list[SessionNote]:
    """Rallies a player lost by hitting the last shot out (from the line calls)."""
    ended: dict[str, list[tuple[Hit, Moment]]] = defaultdict(list)
    out: dict[str, list[Moment]] = defaultdict(list)
    for call in record.line_calls:
        hits = [h for h in record.hits if h.rally_index == call.rally_index]
        if not hits:
            continue
        last = hits[-1]
        moment = Moment(frame=call.frame, time_s=call.time_s, hit_id=last.id)
        who = last.hitter or last.player
        ended[who].append((last, moment))
        if call.effective_call == "out":
            out[who].append(moment)
    notes = []
    for side in sorted(ended, key=list(SIDE).index):
        bad, total = out.get(side, []), len(ended.get(side, []))
        if not bad or len(bad) < cfg["min_count"] or len(bad) / total < cfg["min_rate"]:
            continue
        notes.append(
            SessionNote(
                id=f"shots_out:{side}",
                rule="shots_out",
                player=side,
                text=f"{SIDE[side]}: last shot landed out in {len(bad)} of {total} "
                "rallies they finished",
                count=len(bad),
                total=total,
                severity=float(cfg["severity"].get("shots_out", 1.0)),
                moments=bad[: int(cfg["max_moments"])],
            )
        )
    return notes


def formation_notes(record: ClipRecord, cfg: dict[str, Any]) -> list[SessionNote]:
    """Doubles: how each pair stood during its rallies (not a fault; severity 0).

    Front and back (one partner nearer the net) is the attacking formation, side by side
    the defensive one. A rally counts for the formation the pair held in most of its frames
    with both partners on court.
    """
    from shuttlesense.schema import is_doubles

    if not is_doubles(record) or not record.rallies:
        return []
    notes = []
    for side in ("near", "far"):
        front_back = counted = 0
        for rally in record.rallies:
            votes = []
            for f in record.frames[rally.start_frame : rally.end_frame + 1]:
                pos = f.court_positions
                a = getattr(pos, side, None) if pos else None
                b = getattr(pos, f"{side}_2", None) if pos else None
                if a is not None and b is not None:
                    votes.append(abs(a[1] - b[1]) > abs(a[0] - b[0]))
            if votes:
                counted += 1
                front_back += sum(votes) * 2 > len(votes)
        if not counted:
            continue
        notes.append(
            SessionNote(
                id=f"formation:{side}",
                rule="formation",
                player=side,
                text=f"{PAIR[side]}: front and back (attack) in {front_back} of {counted} "
                f"rallies, side by side (defence) in {counted - front_back}",
                count=front_back,
                total=counted,
                severity=0.0,
            )
        )
    return notes


def build_coaching(record: ClipRecord, feedback_cfg: dict[str, Any] | None = None) -> Coaching:
    """All notes, and the top fixes ranked by faulty strokes x severity, then by rate.

    Formation notes describe doubles play and are never top fixes.
    """
    cfg = pattern_config(feedback_cfg)
    faults = form_notes(record, cfg) + out_notes(record, cfg)
    notes = faults + formation_notes(record, cfg)
    ranked = sorted(faults, key=lambda n: (-n.count * n.severity, -n.count / n.total, n.id))
    return Coaching(session_notes=notes, top_fixes=[n.id for n in ranked[: cfg["top_fixes"]]])
