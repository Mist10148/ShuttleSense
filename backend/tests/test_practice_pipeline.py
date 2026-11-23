import pytest

from shuttlesense.practice.pipeline import PracticeAnalyzer, PracticeSetup
from shuttlesense.schema import Player


def test_paused_frame_requires_reselection_and_does_not_produce_evidence():
    setup = PracticeSetup(
        video_id="a" * 12,
        stroke="clear",
        arm="right",
        attempt_seconds=[0.1],
        selected_bbox=(0, 0, 10, 10),
    )
    analyzer = PracticeAnalyzer(setup, fps=10, frame_count=3)
    player = Player(bbox=(0, 0, 10, 10), score=0.9)
    assert analyzer.process(0, [player]) is not None
    assert analyzer.process(1, []) is None
    assert analyzer.status == "needs_selection"
    assert not analyzer.observations
    with pytest.raises(ValueError):
        analyzer.reselect(2, (0, 0, 10, 10))
    analyzer.reselect(1, (0, 0, 10, 10))
    assert analyzer.process(1, [player]) is not None
    assert len(analyzer.observations) == 1
    assert analyzer.observations[0].moment_s == 0.1
    analyzer.process(2, [player])
    assert analyzer.status == "done"


def test_out_of_range_and_nan_markers_are_rejected():
    with pytest.raises(ValueError):
        PracticeSetup(
            video_id="x",
            stroke="drop",
            arm="left",
            attempt_seconds=[float("nan")],
            selected_bbox=(0, 0, 10, 10),
        )
    setup = PracticeSetup(
        video_id="x", stroke="drop", arm="left", attempt_seconds=[10], selected_bbox=(0, 0, 10, 10)
    )
    with pytest.raises(ValueError):
        PracticeAnalyzer(setup, fps=10, frame_count=3)


def test_automatic_practice_does_not_require_manual_attempts():
    setup = PracticeSetup(video_id="x", stroke="clear", arm="right", selected_bbox=(0, 0, 10, 10))
    analyzer = PracticeAnalyzer(setup, fps=30, frame_count=1)
    assert analyzer.process(0, [Player(bbox=(0, 0, 10, 10), score=0.9)]) is not None
    assert analyzer.status == "done"
    assert not analyzer.observations
