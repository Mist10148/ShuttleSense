"""Next-serve evidence for rally winners (D47): the side that wins a rally serves next."""

from __future__ import annotations

from shuttlesense.referee.rally import next_serve_side
from shuttlesense.schema import ClipRecord, CourtPositions, Frame, Hit, Rally

FPS = 30


def _record(
    hits: list[tuple[int, str, str | None, float | None]],
    *,
    n: int = 900,
    positions: dict[int, CourtPositions] | None = None,
) -> ClipRecord:
    frames = [Frame(frame=i, court_positions=(positions or {}).get(i)) for i in range(n)]
    record = ClipRecord(clip_id="c", fps=FPS, width=1280, height=720, num_frames=n,
                        frames=frames)  # fmt: skip
    record.hits = [
        Hit(id=i, frame=f, time_s=f / FPS, player=side, stroke=stroke, confidence=conf)
        for i, (f, side, stroke, conf) in enumerate(hits)
    ]
    return record


def _rallies(record: ClipRecord, bounds: list[tuple[int, int]]) -> list[Rally]:
    rallies = [Rally(index=i, start_frame=s, end_frame=e) for i, (s, e) in enumerate(bounds)]
    for r in rallies:
        for h in record.hits:
            if r.start_frame <= h.frame <= r.end_frame:
                h.rally_index = r.index
    return rallies


def test_a_clear_serve_names_the_previous_rally_winner() -> None:
    record = _record([(10, "near", "serve", 0.9), (40, "far", "clear", 0.8),
                      (400, "far", "serve", 0.95)])  # fmt: skip
    first, second = _rallies(record, [(10, 200), (400, 899)])
    assert next_serve_side(record, first, second, {}) == "far"


def test_no_serve_evidence_without_a_confident_serve() -> None:
    for stroke, conf in (("lift", 0.9), ("serve", 0.4), ("serve", None), (None, None)):
        record = _record([(10, "near", "serve", 0.9), (400, "far", stroke, conf)])
        first, second = _rallies(record, [(10, 200), (400, 899)])
        assert next_serve_side(record, first, second, {}) is None, (stroke, conf)


def test_a_short_pause_is_a_rally_split_in_two_not_a_new_serve() -> None:
    """A lift that leaves the frame splits a rally; the next 'serve' 1 s later is not one."""
    record = _record([(10, "near", "serve", 0.9), (230, "far", "serve", 0.9)])
    first, second = _rallies(record, [(10, 200), (230, 899)])
    assert next_serve_side(record, first, second, {}) is None


def test_a_long_pause_may_hide_a_change_of_ends() -> None:
    record = _record([(10, "near", "serve", 0.9), (1200, "far", "serve", 0.9)], n=1300)
    first, second = _rallies(record, [(10, 100), (1200, 1299)])
    assert next_serve_side(record, first, second, {}) is None
    loose = {"serve_inference": {"max_pause_s": 60.0}}
    assert next_serve_side(record, first, second, loose) == "far"


def test_the_server_must_stand_where_a_server_can() -> None:
    def at(xy: tuple[float, float]) -> str | None:
        record = _record([(10, "near", "serve", 0.9), (400, "far", "serve", 0.9)],
                         positions={400: CourtPositions(far=xy)})  # fmt: skip
        first, second = _rallies(record, [(10, 200), (400, 899)])
        return next_serve_side(record, first, second, {})

    assert at((1.5, 9.5)) == "far"  # behind the far short service line
    assert at((1.5, 8.2)) == "far"  # just in front of it, within the feet tolerance
    assert at((1.5, 7.2)) is None  # at the net: not a serving position
    assert at((1.5, 4.0)) is None  # on the near half: the side is wrong
    assert at((7.0, 10.0)) is None  # well wide of the doubles sideline


def test_a_doubles_serve_credited_to_the_other_side_is_not_evidence() -> None:
    record = _record([(10, "near", "serve", 0.9), (400, "far", "serve", 0.9)])
    first, second = _rallies(record, [(10, 200), (400, 899)])
    record.hits[1].hitter = "far_2"
    assert next_serve_side(record, first, second, {}) == "far"
    record.hits[1].hitter = "near_1"
    assert next_serve_side(record, first, second, {}) is None


def test_serve_evidence_can_be_switched_off_and_needs_the_next_rally() -> None:
    record = _record([(10, "near", "serve", 0.9), (400, "far", "serve", 0.9)])
    first, second = _rallies(record, [(10, 200), (400, 899)])
    assert next_serve_side(record, first, second, {"serve_inference": {"enabled": False}}) is None
    assert next_serve_side(record, first, None, {}) is None
    assert next_serve_side(record, second, first, {}) is None


def _played(
    first_stroke: str, *, lose_landing: bool = True, plan_second: object = None
) -> ClipRecord:
    """Two synthetic rallies through the hits and referee stages. Near wins the first (it
    lands in on the far half) and serves the second; the first's landing is lost from view
    when `lose_landing`, as on broadcast footage where the falling shuttle is hidden."""
    from shuttlesense import analytics, hits, referee
    from shuttlesense.config import load_config
    from shuttlesense.stage import StageContext
    from shuttlesense.stream.synthetic import PlannedRally, planned_strokes, synthetic_record

    plan = (
        PlannedRally("near", 3, (2.0, 10.0), ("serve", "clear", "smash")),
        plan_second or PlannedRally("near", 2, (2.5, 11.0), (first_stroke, "clear")),
    )
    record, truth = synthetic_record(plan)
    if lose_landing:
        first_landing = truth["landings"][0]
        for f in record.frames[first_landing : truth["starts"][1]]:
            f.shuttle = f.shuttle.model_copy(update={"visible": 0, "x": None, "y": None})
    ctx = StageContext(video_path=None, out_dir=None, config=load_config())
    hits.run(record, ctx)
    strokes = planned_strokes(truth)
    for h in record.hits:
        h.stroke, h.confidence = strokes.get(h.frame), 0.9
    analytics.run(record, ctx)
    return referee.run(record, ctx)


def test_a_rally_lost_from_view_is_scored_from_the_next_serve() -> None:
    record = _played("serve")
    first = record.rallies[0]
    assert first.landing is None and first.winner == "near"
    assert record.rallies[0].score_after is not None
    assert (record.rallies[0].score_after.near, record.rallies[0].score_after.far) == (1, 0)


def test_a_rally_lost_from_view_waits_for_the_user_without_a_clear_serve() -> None:
    """The next rally opens with a lift, not a serve: a rally split by a lift out of the
    frame looks like this, so nobody scores."""
    record = _played("lift")
    assert record.rallies[0].landing is None and record.rallies[0].winner is None


def test_a_seen_landing_still_decides_its_rally() -> None:
    record = _played("lift", lose_landing=False)
    assert record.rallies[0].landing is not None and record.rallies[0].winner == "near"


def test_a_landing_and_a_next_serve_that_disagree_award_nobody() -> None:
    """Near's shot lands in on the far half, yet far serves next: one of the two is wrong."""
    from shuttlesense.stream.synthetic import PlannedRally

    agree = _played("serve", lose_landing=False)
    assert agree.rallies[0].winner == "near"
    record = _played("serve", lose_landing=False, plan_second=PlannedRally(
        "far", 2, (2.5, 3.0), ("serve", "clear")))  # fmt: skip
    assert record.rallies[0].landing is not None and record.rallies[0].landing.in_court
    assert record.rallies[0].winner is None
    assert (record.rallies[0].score_after.near, record.rallies[0].score_after.far) == (0, 0)
