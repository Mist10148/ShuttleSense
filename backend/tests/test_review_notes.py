"""Close calls lean to the likely side; every call the user should check says why (D59)."""

from __future__ import annotations

from shuttlesense.referee.rally import decide_winner, landing_decision, referee_review
from shuttlesense.schema import ClipRecord, Court, Frame, Hit, Landing, LineCall, Rally

FPS = 30


def _record(landing: Landing | None, *, serve_next: str | None = None) -> ClipRecord:
    n = 900
    record = ClipRecord(
        clip_id="c", fps=FPS, width=1280, height=720, num_frames=n,
        frames=[Frame(frame=i) for i in range(n)],
        court=Court(corners_px=((0, 0), (1, 0), (1, 1), (0, 1)),
                    homography=[[0.01, 0, 0], [0, 0.01, 0], [0, 0, 1]]),
    )  # fmt: skip
    hits = [Hit(id=0, frame=10, time_s=10 / FPS, player="near", rally_index=0)]
    rallies = [Rally(index=0, start_frame=10, end_frame=200, landing=landing)]
    if serve_next:
        hits.append(Hit(id=1, frame=400, time_s=400 / FPS, player=serve_next, stroke="serve",
                        confidence=0.95, rally_index=1))  # fmt: skip
        rallies.append(Rally(index=1, start_frame=400, end_frame=899))
    record.hits, record.rallies = hits, rallies
    if landing is not None:
        margin = 3.0 if landing.in_court else -3.0
        record.line_calls = [LineCall(id=0, rally_index=0, frame=200, time_s=200 / FPS,
                                      call="in" if landing.in_court else "out",
                                      landing_xy=(landing.x_m, landing.y_m), margin_cm=margin,
                                      confidence=landing.confidence,
                                      uncertain=landing.confidence < 0.5)]  # fmt: skip
    return record


CLOSE_IN = Landing(x_m=2.0, y_m=13.37, in_court=True, confidence=0.3)  # 3 cm inside the back line


def test_a_close_call_goes_to_the_likely_side_and_says_so() -> None:
    record = _record(CLOSE_IN)
    decision = landing_decision(record, record.rallies[0])
    assert decision.winner == "near" and not decision.certain
    record.rallies[0].winner = decide_winner(record, record.rallies[0], None, None)
    assert record.rallies[0].winner == "near"
    review = referee_review(record, record.rallies[0])
    assert review == "Close call: looks IN by 3 cm at the back line. Check it"


def test_a_clear_next_serve_overrules_a_close_call() -> None:
    record = _record(CLOSE_IN, serve_next="far")
    rally, following = record.rallies
    rally.winner = decide_winner(record, rally, following, None)
    assert rally.winner == "far"
    assert "far, who served next" in (referee_review(record, rally) or "")


def test_a_certain_call_needs_no_review() -> None:
    record = _record(Landing(x_m=2.0, y_m=10.0, in_court=True, confidence=1.0))
    record.rallies[0].winner = decide_winner(record, record.rallies[0], None, None)
    assert record.rallies[0].winner == "near"
    assert referee_review(record, record.rallies[0]) is None


def test_uncalled_rallies_say_why() -> None:
    none = _record(None)
    assert landing_decision(none, none.rallies[0]).winner is None
    assert "no landing was seen" in (referee_review(none, none.rallies[0]) or "")
    far_off = _record(Landing(x_m=2.0, y_m=17.0, in_court=False, confidence=1.0))
    assert landing_decision(far_off, far_off.rallies[0]).winner is None
    assert "far outside the court" in (referee_review(far_off, far_off.rallies[0]) or "")
