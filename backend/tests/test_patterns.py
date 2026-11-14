from __future__ import annotations

from shuttlesense.feedback import build_coaching
from shuttlesense.feedback.patterns import pattern_config
from shuttlesense.schema import ClipRecord, FeedbackItem, Hit, LineCall


def _hit(i: int, player: str, stroke: str, passed: dict[str, bool], rally: int = 0) -> Hit:
    return Hit(
        id=i,
        frame=10 * i,
        time_s=i / 3,
        player=player,
        stroke=stroke,
        rally_index=rally,
        feedback=[FeedbackItem(rule=r, passed=p) for r, p in passed.items()],
    )


def _record(hits: list[Hit], calls: list[LineCall] = ()) -> ClipRecord:
    return ClipRecord(
        clip_id="c", fps=30, width=1280, height=720, num_frames=200, hits=hits,
        line_calls=list(calls),
    )  # fmt: skip


def _smashes(bad: int, total: int, player: str = "near") -> list[Hit]:
    return [
        _hit(i, player, "smash", {"elbow_extension": i >= bad, "contact_above_head": True})
        for i in range(total)
    ]


def test_repeated_fault_becomes_a_note_with_moments() -> None:
    coaching = build_coaching(_record(_smashes(3, 5)))
    note = coaching.session_notes[0]
    assert note.id == "elbow_extension:near" and note.player == "near"
    assert note.text == "Near player: Bent hitting arm at contact on 3 of 5 smashes"
    assert (note.count, note.total, note.stroke) == (3, 5, "smash")
    assert [m.hit_id for m in note.moments] == [0, 1, 2]
    assert coaching.top_fixes == ["elbow_extension:near"]


def test_thresholds_filter_rare_faults() -> None:
    assert build_coaching(_record(_smashes(1, 5))).session_notes == []  # count < 2
    assert build_coaching(_record(_smashes(2, 5))).session_notes == []  # rate < 0.5
    loose = {"patterns": {"min_count": 1, "min_rate": 0.2}}
    assert len(build_coaching(_record(_smashes(1, 5)), loose).session_notes) == 1


def test_notes_are_per_player_and_name_mixed_strokes() -> None:
    hits = _smashes(2, 2, "far") + [
        _hit(10 + i, "far", "clear", {"elbow_extension": False}) for i in range(2)
    ]
    note = build_coaching(_record(hits)).session_notes[0]
    assert note.text == "Far player: Bent hitting arm at contact on 4 of 4 clears and smashes"
    assert note.stroke is None


def test_ranking_uses_count_times_severity_and_is_deterministic() -> None:
    hits = _smashes(3, 3) + [
        _hit(20 + i, "near", "serve", {"stable_feet": False}, rally=1) for i in range(2)
    ]
    record = _record(hits)
    first = build_coaching(record)
    # 2 serve pose cues rank below 3 smash cues at the same severity.
    # so the id breaks the tie.
    assert first.top_fixes == ["elbow_extension:near", "stable_feet:near"]
    assert build_coaching(record) == first


def test_out_shots_come_from_line_calls_and_overrides() -> None:
    hits = [_hit(i, "near", "smash", {}, rally=i) for i in range(3)]
    calls = [
        LineCall(id=i, rally_index=i, frame=10 * i + 5, time_s=i / 3 + 0.1, call=c,
                 landing_xy=(2.0, 14.0), margin_cm=-50.0, confidence=1.0, uncertain=False)
        for i, c in enumerate(["out", "out", "in"])
    ]  # fmt: skip
    note = build_coaching(_record(hits, calls)).session_notes[0]
    assert note.id == "shots_out:near" and (note.count, note.total) == (2, 3)
    assert [m.frame for m in note.moments] == [5, 15]


def test_top_fix_count_is_configurable() -> None:
    cfg = pattern_config({"patterns": {"top_fixes": 1, "severity": {"elbow_extension": 2}}})
    assert cfg["top_fixes"] == 1 and cfg["severity"]["stable_feet"] == 1.0
    assert cfg["severity"]["elbow_extension"] == 2


def test_uncertain_unconfirmed_calls_are_not_counted_as_shots_out() -> None:
    """An uncertain call decides no rally, so it must not be blamed on the player."""
    hits = [_hit(i, "near", "smash", {}, rally=i) for i in range(3)]
    calls = [
        LineCall(id=i, rally_index=i, frame=10 * i + 5, time_s=i / 3 + 0.1, call="out",
                 landing_xy=(2.0, 14.0), margin_cm=-3.0, confidence=0.3, uncertain=True)
        for i in range(3)
    ]  # fmt: skip
    assert not [n for n in build_coaching(_record(hits, calls)).session_notes
                if n.rule == "shots_out"]  # fmt: skip
    from shuttlesense.schema import LineCallOverride

    for c in calls[:2]:
        c.override = LineCallOverride(call="out", at="2026-11-14T10:00:00Z")
    note = next(n for n in build_coaching(_record(hits, calls)).session_notes
                if n.rule == "shots_out")  # fmt: skip
    assert (note.count, note.total) == (2, 2)
