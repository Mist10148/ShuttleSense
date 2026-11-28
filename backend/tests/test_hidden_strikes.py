"""Who struck the shuttle last, when the hit detector missed a touch (D61)."""

from __future__ import annotations

import numpy as np

from shuttlesense.referee.rally import landing_decision
from shuttlesense.referee.strikes import final_striker
from shuttlesense.schema import ClipRecord, Frame, Hit, Landing, Player, Players, Rally, Shuttle

NEAR_WRIST = (600.0, 520.0)
TOUCH = (640.0, 236.0)  # where the far player touches it at frame 40
LANDING_FRAME = 70


def _player(wrist: tuple[float, float]) -> Player:
    keypoints = [(wrist[0], wrist[1] - 60.0, 0.9)] * 17
    keypoints[9] = keypoints[10] = (wrist[0], wrist[1], 0.9)
    return Player(bbox=(wrist[0] - 30, wrist[1] - 80, 60.0, 160.0), keypoints=keypoints)


def _path() -> np.ndarray:
    """Near hits at 10; up, then down into the touch at 40; up again; down to land at 70."""
    keys = [(10, (600.0, 500.0)), (25, (620.0, 150.0)), (40, TOUCH), (52, (560.0, 190.0)),
            (LANDING_FRAME, (450.0, 240.0))]  # fmt: skip
    xy = np.zeros((90, 2))
    for (f0, p0), (f1, p1) in zip(keys[:-1], keys[1:], strict=True):
        for f in range(f0, f1 + 1):
            t = (f - f0) / (f1 - f0)
            xy[f] = np.add(p0, np.multiply(t, np.subtract(p1, p0)))
    xy[LANDING_FRAME:] = keys[-1][1]
    xy[:10] = keys[0][1]
    return xy


def _record(far_wrist: tuple[float, float] | None, near_wrist=NEAR_WRIST) -> ClipRecord:
    xy = _path()
    frames = []
    for i, (x, y) in enumerate(xy):
        players = Players(
            near=_player(near_wrist if 35 <= i <= 45 else NEAR_WRIST),
            far=_player(far_wrist) if far_wrist else None,
        )
        frames.append(Frame(frame=i, shuttle=Shuttle(x=x, y=y, visible=1), players=players))
    record = ClipRecord(clip_id="c", fps=30, width=1280, height=720, num_frames=len(frames),
                        frames=frames, hits=[Hit(id=0, frame=10, time_s=0.33, player="near",
                                                 rally_index=0)])  # fmt: skip
    # Out behind the far baseline.
    landing = Landing(x_m=1.1, y_m=15.0, in_court=False, confidence=1.0)
    record.rallies = [Rally(index=0, start_frame=10, end_frame=LANDING_FRAME, landing=landing)]
    return record


def test_a_touch_the_detector_missed_is_found_on_the_track() -> None:
    record = _record(far_wrist=(645.0, 240.0))
    striker = final_striker(record, record.hits, LANDING_FRAME)
    assert striker is not None and striker.side == "far" and striker.hidden and striker.clear
    assert abs(striker.frame - 40) <= 2


def test_an_out_on_the_strikers_own_half_is_their_fault() -> None:
    """The old rule credited near's hit and gave far the point. Far touched it last and it
    landed out behind far's own baseline: far's shot never crossed, so near wins."""
    decision = landing_decision(_record(far_wrist=(645.0, 240.0)), _rally())
    assert decision.winner == "near" and decision.certain


def test_a_gap_after_the_strike_could_hide_a_return() -> None:
    record = _record(far_wrist=(645.0, 240.0))
    for f in record.frames[48:58]:
        f.shuttle = Shuttle()  # out of view mid-flight: a near return could be in there
    assert landing_decision(record, record.rallies[0]).winner is None


def test_a_touch_nobody_can_be_credited_with_withholds_the_out_call() -> None:
    # Both sides' wrists equally close to the touch: the striker is unknown.
    record = _record(far_wrist=(660.0, 236.0), near_wrist=(620.0, 236.0))
    striker = final_striker(record, record.hits, LANDING_FRAME)
    assert striker is not None and striker.side is None
    assert landing_decision(record, record.rallies[0]).winner is None


def test_a_turn_with_no_wrist_near_is_not_a_strike() -> None:
    """A deflection off the net tape, say: the detected hit stands, OUT on far's half."""
    record = _record(far_wrist=None)
    striker = final_striker(record, record.hits, LANDING_FRAME)
    assert striker is not None and striker.side == "near" and not striker.hidden
    assert landing_decision(record, record.rallies[0]).winner == "far"


def test_an_in_call_does_not_depend_on_the_striker() -> None:
    record = _record(far_wrist=(660.0, 236.0), near_wrist=(620.0, 236.0))
    record.rallies[0].landing = Landing(x_m=2.0, y_m=10.0, in_court=True, confidence=1.0)
    assert landing_decision(record, record.rallies[0]).winner == "near"


def _rally() -> Rally:
    return _record(far_wrist=(645.0, 240.0)).rallies[0]


def test_an_out_override_credits_the_touch_found_on_the_track() -> None:
    """The user confirms OUT; far's missed touch sent it out behind far's own baseline, so
    near wins, as the automated call would say. The old override credited near's hit."""
    from datetime import UTC, datetime

    from shuttlesense.referee.linecalls import LineCallOverrideIn, apply_overrides
    from shuttlesense.schema import LineCall

    record = _record(far_wrist=(645.0, 240.0))
    record.line_calls = [
        LineCall(
            id=0,
            rally_index=0,
            frame=LANDING_FRAME,
            time_s=LANDING_FRAME / 30,
            call="in",
            landing_xy=(1.1, 15.0),
            margin_cm=-1.0,
            confidence=0.1,
            uncertain=True,
        )
    ]
    apply_overrides(record, [LineCallOverrideIn(rally_index=0, call="out", at=datetime.now(UTC))])
    assert record.rallies[0].winner == "near"
