from __future__ import annotations

import numpy as np

from shuttlesense.config import load_config
from shuttlesense.hits.detector import vertical_flips
from shuttlesense.schema import Shuttle
from shuttlesense.stream.analyzer import StreamAnalyzer
from shuttlesense.stream.synthetic import synthetic_record
from shuttlesense.timing import frames_at, scaled


def test_frame_counts_cover_the_same_time_at_any_rate() -> None:
    assert frames_at(30, 30) == 30 and frames_at(30, 25) == 25 and frames_at(30, 10) == 10
    assert frames_at(8, 15) == 4 and frames_at(20, 60) == 40
    assert frames_at(3, 5) == 1  # never zero
    assert frames_at(8, None) == 8 and frames_at(8, 0) == 8  # unknown rate: as configured
    cfg = {"lost_frames_end": 30, "stationary_frames_end": 20, "line_call": {"court": "singles"}}
    out = scaled(cfg, ("lost_frames_end", "stationary_frames_end", "absent"), 15)
    assert out == {
        "lost_frames_end": 15,
        "stationary_frames_end": 10,
        "line_call": cfg["line_call"],
    }
    assert cfg["lost_frames_end"] == 30  # the config itself is not changed


def test_live_lags_follow_the_session_rate() -> None:
    config = load_config()
    fast = StreamAnalyzer(clip_id="a", fps=30, width=1280, height=720, court=None, config=config)
    slow = StreamAnalyzer(clip_id="b", fps=10, width=1280, height=720, court=None, config=config)
    assert fast.min_gap == 8 and slow.min_gap == 3
    assert slow.rally_settle < fast.rally_settle


def test_jitter_is_not_a_down_to_up_turn() -> None:
    # A shuttle held before the serve wobbles by a pixel; a struck one turns by many.
    held = np.array([[300, 400], [300, 401], [300, 400], [301, 401], [300, 400]], float)
    assert vertical_flips(held) == [1, 3]  # every wobble, with no threshold
    assert vertical_flips(held, min_px=2.0) == []
    struck = np.array([[300, 380], [300, 390], [300, 400], [305, 380], [310, 360]], float)
    assert vertical_flips(struck, min_px=2.0) == [2]


def test_live_window_drops_a_burst_of_false_detections() -> None:
    record, truth = synthetic_record()
    hits = [f for f, _, _ in truth["hits"]]
    # Three frames in mid-flight where the tracker jumped to something else entirely.
    at = (hits[1] + hits[2]) // 2
    for f in record.frames[at - 1 : at + 2]:
        f.shuttle = Shuttle(x=40.0, y=30.0, visible=1)

    def live_hits(rectify: bool) -> list[tuple[int, str]]:
        config = {**load_config()}
        config["live"] = {**config["live"], "rectify_track": rectify}
        a = StreamAnalyzer(clip_id="live", fps=record.fps, width=record.width,
                           height=record.height, court=record.court, config=config)  # fmt: skip
        for f in record.frames:
            a.add_frame(f.shuttle, f.players)
        return [(h.frame, h.player) for h in a.finalize().hits]

    assert live_hits(True) == [(f, s) for f, s, _ in truth["hits"]]
    # The session's record keeps what the model saw: only the stages' copy is cleaned.
    assert record.frames[at].shuttle.x == 40.0
