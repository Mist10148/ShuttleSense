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
