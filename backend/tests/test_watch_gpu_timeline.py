import pytest
from test_eval_scripts import load_script


def test_timeline_unions_and_intersections_do_not_double_count():
    timeline = load_script("summarize_watch_gpu_timeline")
    intervals = [(7, 10), (0, 5), (3, 8), (12, 12)]
    assert timeline.merge(intervals) == [(0, 10)]
    assert timeline.intersect(intervals, [(2, 4), (6, 12)]) == [(2, 4), (6, 10)]
    assert timeline.duration([(0, 5), (3, 8), (8, 10)]) == pytest.approx(10)
    assert timeline.intersect([], intervals) == []
