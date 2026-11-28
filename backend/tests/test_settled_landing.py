"""The last rally ends where the shuttle settled before the clip ended (D48)."""

from __future__ import annotations

import numpy as np

from shuttlesense.referee.rally import scaled_pixels, segment_rallies

CFG = scaled_pixels({"lost_frames_end": 30, "stationary_frames_end": 20}, 720)


def _falls_then_lies(still: int, jitter: float = 0.0, seed: int = 0):
    """A shuttle hit at frame 2 that flies, comes down at frame 40 and lies still for
    `still` frames before the clip ends."""
    n = 40 + still
    xy = np.array([[300.0 + 5 * i, 100.0 + 4 * i] for i in range(n)])
    rng = np.random.default_rng(seed)
    xy[40:] = np.array([500.0, 260.0]) + rng.uniform(-jitter, jitter, size=(still, 2))
    return np.ones(n, dtype=int), xy


def test_a_shuttle_settled_just_before_the_clip_ends_is_a_landing() -> None:
    """The session stopped 12 frames after the landing: too short for the 20-frame rule,
    but nothing can follow the last frame, so the rally ends there."""
    visible, xy = _falls_then_lies(12, jitter=3.0)
    seg = segment_rallies(visible, xy, [2], CFG)[0]
    assert seg.closed and seg.landing_frame == 40 and seg.end == 40
    assert np.allclose(seg.landing_px, (500.0, 260.0), atol=3.0)


def test_a_short_rest_at_the_end_lands_where_the_shuttle_lies() -> None:
    """Five still frames after a fall are short of end_rest_frames, but the shuttle came down
    and stopped as the clip ended: it landed there (D60)."""
    visible, xy = _falls_then_lies(5)
    seg = segment_rallies(visible, xy, [2], CFG)[0]
    assert seg.closed and np.allclose(seg.landing_px, (500.0, 260.0))


def test_a_shuttle_still_flying_at_the_end_leaves_the_rally_open() -> None:
    visible, xy = _falls_then_lies(5)
    xy[40:] = [[500.0 + 5 * k, 260.0 + 4 * k] for k in range(5)]  # never slows down
    seg = segment_rallies(visible, xy, [2], CFG)[0]
    assert not seg.closed and seg.landing_frame is None


def test_a_rest_the_shuttle_leaves_before_the_end_is_not_a_landing() -> None:
    """Still for 10 frames, then flying again (a missed hit): play went on."""
    visible, xy = _falls_then_lies(30)
    xy[50:] = [[500.0 + 8 * k, 260.0 - 6 * k] for k in range(20)]
    seg = segment_rallies(visible, xy, [2], CFG)[0]
    assert not seg.closed


def test_a_detection_that_never_moved_does_not_end_the_last_rally() -> None:
    n = 30
    xy = np.tile([400.0, 300.0], (n, 1))
    visible = np.zeros(n, dtype=int)
    visible[2:4] = 1  # the serve, then only a fixed bright spot at the same place
    visible[12:] = 1
    seg = segment_rallies(visible, xy, [2], CFG)[0]
    assert not seg.closed


def test_unobserved_frames_after_the_last_hit_give_nothing() -> None:
    visible, xy = _falls_then_lies(12)
    seg = segment_rallies(visible, xy, [2], CFG, unobserved={45})[0]
    assert not seg.closed


def test_a_live_session_stopped_after_a_landing_scores_it_like_the_upload() -> None:
    """A synthetic rally cut 12 frames after its in landing on the far half: offline and a
    live session stopped there both give near the point."""
    from shuttlesense import analytics, feedback, hits, referee
    from shuttlesense.config import load_config
    from shuttlesense.stage import StageContext
    from shuttlesense.stream.analyzer import StreamAnalyzer
    from shuttlesense.stream.synthetic import PlannedRally, synthetic_record

    record, truth = synthetic_record((PlannedRally("near", 3, (2.0, 7.4)),))
    cut = truth["landings"][0] + 12
    record.frames = record.frames[:cut]
    record.num_frames = cut
    config = load_config()
    offline = record.model_copy(deep=True)
    ctx = StageContext(video_path=None, out_dir=None, config=config)
    for stage in (hits, feedback, analytics, referee):
        stage.run(offline, ctx)
    assert offline.rallies[0].winner == "near"
    assert offline.rallies[0].landing is not None and offline.rallies[0].landing.in_court
    assert (offline.score.near, offline.score.far) == (1, 0)

    live = StreamAnalyzer(clip_id="live", fps=record.fps, width=record.width,
                          height=record.height, court=record.court, config=config)  # fmt: skip
    for f in record.frames:
        live.add_frame(f.shuttle, f.players)
    final = live.finalize()
    assert [r.winner for r in final.rallies] == ["near"]
    assert (final.score.near, final.score.far) == (1, 0)
