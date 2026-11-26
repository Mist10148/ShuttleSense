from __future__ import annotations

import json
from datetime import UTC, datetime

import numpy as np
import pytest

from shuttlesense.court import compute_homography, play_bounds, service_bounds
from shuttlesense.referee.linecalls import (
    DEFAULTS,
    LineCallOverrideIn,
    apply_overrides,
    call_landing,
    derive_from_rallies,
    meters_per_pixel,
    signed_margin,
    uncertainty_band,
)
from shuttlesense.schema import (
    ClipRecord,
    Court,
    CourtPositions,
    Frame,
    Hit,
    Landing,
    Rally,
    Score,
    load_record,
)

SINGLES = play_bounds("singles")
CORNERS = ((212.0, 650.0), (1068.0, 650.0), (880.0, 210.0), (400.0, 210.0))


def test_signed_margin_inside_outside_and_on_the_line() -> None:
    assert signed_margin((2.5, 10.0), SINGLES) == pytest.approx(2.5)
    assert signed_margin((5.18, 10.0), SINGLES) == 0.0  # lines are in
    assert signed_margin((5.30, 10.0), SINGLES) == pytest.approx(-0.12)
    assert signed_margin((6.18, 14.40), SINGLES) == pytest.approx(-np.sqrt(2))


def test_clear_calls_are_certain() -> None:
    assert call_landing((2.5, 10.0), SINGLES, 0.1) == ("in", 2.5, 1.0, False)
    call, margin, confidence, uncertain = call_landing((2.0, 14.0), SINGLES, 0.1)
    assert call == "out" and margin == pytest.approx(-0.6) and confidence == 1.0
    assert not uncertain


def test_call_inside_the_band_is_uncertain() -> None:
    call, margin, confidence, uncertain = call_landing((5.12, 10.0), SINGLES, 0.1)
    assert call == "in" and uncertain and confidence < 0.5
    assert margin == pytest.approx(0.06)
    # Past the band the call is certain; confidence reaches 1 at twice the band.
    _, _, confidence, uncertain = call_landing((5.03, 10.0), SINGLES, 0.1)
    assert not uncertain and confidence == pytest.approx(0.75)
    # Just inside the band, confidence must not round up to 0.5 (which awards the rally).
    _, _, confidence, uncertain = call_landing((5.18 - 0.09999, 10.0), SINGLES, 0.1)
    assert uncertain and confidence < 0.5


def test_doubles_lines_are_wider() -> None:
    doubles = play_bounds("doubles")
    assert call_landing((5.40, 10.0), SINGLES, 0.05)[0] == "out"
    assert call_landing((5.40, 10.0), doubles, 0.05)[0] == "in"
    assert doubles[0] == pytest.approx(-0.46) and doubles[1] == pytest.approx(5.64)


def test_serve_goes_to_the_diagonal_service_court() -> None:
    # Near server right of the centre line serves to the far court left of it.
    box = service_bounds("near", 3.5)
    assert box[:2] == (0.0, 2.59) and box[2] == pytest.approx(6.7 + 1.98)
    assert call_landing((1.0, 11.0), box, 0.05)[0] == "in"
    assert call_landing((4.0, 11.0), box, 0.05)[0] == "out"  # wrong half
    assert call_landing((1.0, 7.5), box, 0.05)[0] == "out"  # short of the short service line
    # Doubles serves must land before the long service line.
    assert call_landing((1.0, 13.0), service_bounds("near", 3.5, "doubles"), 0.05)[0] == "out"


def test_band_grows_toward_the_far_baseline() -> None:
    h = compute_homography(CORNERS)
    near = uncertainty_band(DEFAULTS, h, (2.6, 0.5))
    far = uncertainty_band(DEFAULTS, h, (2.6, 13.0))
    assert far > near >= DEFAULTS["min_band_m"]
    assert meters_per_pixel(h, (2.6, 13.0)) > meters_per_pixel(h, (2.6, 0.5))
    assert uncertainty_band(DEFAULTS) == DEFAULTS["min_band_m"]  # no homography


def _record(landing_x: float, last: str = "near") -> ClipRecord:
    h = compute_homography(CORNERS)
    frames = [Frame(frame=i, court_positions=CourtPositions(near=(3.5, 1.0))) for i in range(30)]
    return ClipRecord(
        clip_id="c",
        fps=30,
        width=1280,
        height=720,
        num_frames=30,
        court=Court(corners_px=CORNERS, homography=h.tolist()),
        frames=frames,
        hits=[
            Hit(id=0, frame=2, time_s=0.067, player="far", stroke="clear", rally_index=0),
            Hit(id=1, frame=10, time_s=0.333, player=last, stroke="smash", rally_index=0),
        ],
        rallies=[
            Rally(
                index=0,
                start_frame=0,
                end_frame=20,
                landing=Landing(x_m=landing_x, y_m=10.0, in_court=True, confidence=0.3),
            )
        ],
        score=Score(),
    )


def test_derive_from_rallies_and_override_rescores() -> None:
    record = _record(5.15)
    calls = derive_from_rallies(record)
    assert len(calls) == 1 and calls[0].uncertain and calls[0].call == "in"
    assert calls[0].frame == 20 and calls[0].time_s == pytest.approx(0.667)
    record.line_calls = calls
    at = datetime(2026, 11, 17, tzinfo=UTC)
    apply_overrides(record, [LineCallOverrideIn(rally_index=0, call="out", at=at)])
    assert record.line_calls[0].effective_call == "out"
    assert record.rallies[0].landing.in_court is False
    assert record.rallies[0].winner == "far"  # near hit it out


def test_migrated_1_0_record_gets_line_calls() -> None:
    data = _record(2.0).model_dump(mode="json")
    data["schema_version"] = "1.0"
    for key in ("mode", "line_calls", "rally_events", "coaching", "chat"):
        data.pop(key)
    record = load_record(json.dumps(data))
    assert [c.call for c in record.line_calls] == ["in"]
    assert [e.type for e in record.rally_events][:2] == ["rally_start", "hit"]


def test_implausible_landings_never_decide_a_rally() -> None:
    from shuttlesense.referee.linecalls import line_call_config, make_line_call

    record = _record(2.0)
    rally, cfg = record.rallies[0], line_call_config(None)
    clear_out = make_line_call(record, rally, 20, (2.6, 14.0), cfg)
    assert clear_out.call == "out" and not clear_out.uncertain  # a shot just long is a call
    stands = make_line_call(record, rally, 20, (2.6, 13.4 + 3.0), cfg)
    assert stands.call == "out" and stands.uncertain and stands.confidence < 0.5
    on_net = make_line_call(record, rally, 20, (2.6, 6.72), cfg)
    assert on_net.call == "in" and on_net.uncertain  # which half is unknown
    mid_half = make_line_call(record, rally, 20, (2.6, 8.0), cfg)
    assert mid_half.call == "in" and not mid_half.uncertain


@pytest.mark.parametrize("server_x", [None, 2.60, 3.5])
@pytest.mark.parametrize("side", ["near", "far"])
def test_service_box_uncertainty_and_rear_strip(server_x, side):
    from shuttlesense.referee.linecalls import make_line_call

    record = _record(1)
    serve = record.hits[0]
    serve.player, serve.stroke = side, "serve"
    record.hits = [serve]
    pos = CourtPositions()
    setattr(pos, side, (server_x, 1 if side == "near" else 12) if server_x else None)
    record.frames[serve.frame].court_positions = pos
    rally = record.rallies[0]

    def landing(x, y, court):
        return make_line_call(record, rally, 20, (x, y if side == "near" else 13.4 - y),
                              {**DEFAULTS, "court": court})

    legal = landing(1, 11, "singles")
    assert legal.call == "in" and legal.uncertain == (server_x != 3.5)
    wrong = landing(4, 11, "singles")
    assert wrong.uncertain == (server_x != 3.5)
    if server_x == 3.5:
        assert wrong.call == "out"
    short = landing(1, 7.5, "singles")
    assert short.call == "out" and not short.uncertain
    deep = landing(1, 13, "doubles")
    assert deep.call == "out" and not deep.uncertain
    serve.stroke = "clear"
    deep = landing(1, 13, "doubles")
    assert deep.call == "in" and not deep.uncertain
