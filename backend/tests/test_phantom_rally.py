"""A hit detected on a shuttle that never flew is not a rally (D62)."""

from __future__ import annotations

from shuttlesense.referee.rally import run
from shuttlesense.schema import ClipRecord, Frame, Hit, Shuttle
from shuttlesense.stage import StageContext

CFG = {"stages": {"referee": {"lost_frames_end": 30, "stationary_frames_end": 20}}}


def _record(points: list[tuple[float, float] | None], hits: list[tuple[int, str]]) -> ClipRecord:
    frames = [
        Frame(frame=i, shuttle=Shuttle(x=p[0], y=p[1], visible=1) if p else Shuttle())
        for i, p in enumerate(points)
    ]
    return ClipRecord(
        clip_id="c", fps=30, width=1280, height=720, num_frames=len(frames), frames=frames,
        hits=[Hit(id=i, frame=f, time_s=f / 30, player=s) for i, (f, s) in enumerate(hits)],
    )  # fmt: skip


def _flight(n: int) -> list[tuple[float, float]]:
    return [(100.0 + 9 * i, 300.0 - 4 * (i % 20)) for i in range(n)]


def test_a_hit_on_a_shuttle_lying_still_is_not_a_rally() -> None:
    # A rally (hits at 5 and 25), the shuttle lost, then found lying still with a "hit" on it.
    points: list[tuple[float, float] | None] = [*_flight(50), *[None] * 40]
    points += [(435.0, 240.0)] * 15
    record = _record(points, [(5, "near"), (25, "far"), (93, "far")])
    out = run(record, StageContext(video_path=None, out_dir=None, config=CFG))
    assert [(r.start_frame, r.stroke_count) for r in out.rallies] == [(0, 2)]
    assert out.hits[-1].rally_index is None


def test_a_one_hit_rally_that_flew_is_kept() -> None:
    points: list[tuple[float, float] | None] = [None] * 5 + _flight(40) + [None] * 40
    record = _record(points, [(6, "near")])
    out = run(record, StageContext(video_path=None, out_dir=None, config=CFG))
    assert len(out.rallies) == 1 and out.hits[0].rally_index == 0
