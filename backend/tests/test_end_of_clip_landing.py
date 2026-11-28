"""A shuttle still coming down as the clip ends is called where it was last seen (D60)."""

from __future__ import annotations

import numpy as np

from shuttlesense.referee.rally import scaled_pixels, segment_rallies

CFG = scaled_pixels({"lost_frames_end": 30, "stationary_frames_end": 20}, 720)


def _comes_down_as_the_clip_ends(final_step: float = 3.0, rising_before: bool = False):
    """Hit at 2, a fast flight, then slower and slower as it reaches the floor at the end.

    Like the clip in the bug report: the last frames move 2-5 px, the frames before them
    10 or so, the flight itself 30 or more.
    """
    xy: list[list[float]] = []
    x, y = 300.0, 500.0
    for _ in range(20):  # the flight from the hit: up the image, fast
        x, y = x + 8, y - 30
        xy.append([x, y])
    for _ in range(14):  # coming down, fast
        x, y = x - 6, y + (-10 if rising_before else 10)
        xy.append([x, y])
    for _ in range(6):  # sliding to a stop on the floor
        x, y = x - final_step / 2, y + final_step
        xy.append([x, y])
    xy = [[300.0, 500.0]] * 2 + xy
    return np.ones(len(xy), dtype=int), np.asarray(xy)


def test_a_shuttle_still_settling_at_the_end_is_a_landing() -> None:
    visible, xy = _comes_down_as_the_clip_ends()
    seg = segment_rallies(visible, xy, [2], CFG)[0]
    n = len(xy)
    assert seg.closed and seg.landing_frame == n - 1 and seg.end == n - 1
    assert np.allclose(seg.landing_px, xy[-1])
    assert seg.moving_from_px is not None and np.allclose(seg.moving_from_px, xy[-4])


def test_a_shuttle_still_flying_at_the_end_is_not_a_landing() -> None:
    visible, xy = _comes_down_as_the_clip_ends(final_step=12.0)
    assert not segment_rallies(visible, xy, [2], CFG)[0].closed


def test_a_slow_shuttle_at_the_top_of_its_flight_is_not_a_landing() -> None:
    """Rising just before: the slow end is the top of a lift, not the floor."""
    visible, xy = _comes_down_as_the_clip_ends(rising_before=True)
    assert not segment_rallies(visible, xy, [2], CFG)[0].closed


def test_too_soon_after_the_last_hit_is_not_a_landing() -> None:
    visible, xy = _comes_down_as_the_clip_ends()
    n = len(xy)
    assert not segment_rallies(visible, xy, [n - 10], CFG)[0].closed


def test_unseen_last_frames_or_unobserved_frames_give_nothing() -> None:
    visible, xy = _comes_down_as_the_clip_ends()
    visible[-3:] = 0
    assert not segment_rallies(visible, xy, [2], CFG)[0].closed
    visible, xy = _comes_down_as_the_clip_ends()
    assert not segment_rallies(visible, xy, [2], CFG, unobserved={30})[0].closed


def test_the_band_grows_with_how_far_it_was_still_moving() -> None:
    """Offline and live: a synthetic rally cut while its shuttle still slides 2 px a frame."""
    from shuttlesense import analytics, feedback, hits, referee
    from shuttlesense.config import load_config
    from shuttlesense.stage import StageContext
    from shuttlesense.stream.analyzer import StreamAnalyzer
    from shuttlesense.stream.synthetic import PlannedRally, synthetic_record

    record, truth = synthetic_record((PlannedRally("near", 3, (2.0, 7.4)),))
    landing = truth["landings"][0]
    cut = landing + 4
    record.frames = record.frames[:cut]
    record.num_frames = cut
    for k, f in enumerate(record.frames[landing - 6 : cut]):
        f.shuttle = f.shuttle.model_copy(update={"x": f.shuttle.x + 2.0 * k})
    config = load_config()
    offline = record.model_copy(deep=True)
    ctx = StageContext(video_path=None, out_dir=None, config=config)
    for stage in (hits, feedback, analytics, referee):
        stage.run(offline, ctx)
    assert offline.rallies[0].landing is not None
    assert offline.rallies[0].winner == "near"

    live = StreamAnalyzer(clip_id="live", fps=record.fps, width=record.width,
                          height=record.height, court=record.court, config=config)  # fmt: skip
    for f in record.frames:
        live.add_frame(f.shuttle, f.players)
    final = live.finalize()
    assert [r.winner for r in final.rallies] == ["near"]
    assert final.line_calls[0].confidence == offline.line_calls[0].confidence
