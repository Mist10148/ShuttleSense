from __future__ import annotations

import numpy as np
import pytest

from shuttlesense.evaluation import (
    hit_metrics,
    match_events,
    rally_boundary_accuracy,
    tracking_accuracy,
)


def test_hit_matching_within_tolerance() -> None:
    assert match_events([10, 21, 50], [12, 20, 40], tolerance=3) == [(0, 0), (1, 1)]
    # One prediction cannot match two truths.
    assert match_events([10], [9, 11], tolerance=3) == [(0, 0)]
    m = hit_metrics([(10, "near"), (21, "far"), (50, "near")],
                    [(12, "near"), (20, "near"), (40, "far")])  # fmt: skip
    assert m["precision"] == pytest.approx(2 / 3) and m["recall"] == pytest.approx(2 / 3)
    assert m["f1"] == pytest.approx(2 / 3) and m["player_accuracy"] == 0.5


def test_tracking_accuracy_metric() -> None:
    true_xy = np.array([[10, 10], [20, 20], [0, 0], [40, 40]], float)
    true_vis = np.array([1, 1, 0, 1])
    pred_xy = np.array([[12, 11], [30, 20], [0, 0], [0, 0]], float)
    pred_vis = np.array([1, 1, 0, 0])
    m = tracking_accuracy(pred_xy, pred_vis, true_xy, true_vis, tolerance_px=4)
    assert m["accuracy"] == 0.5  # frames 0 (close) and 2 (both invisible)
    assert m["precision"] == 0.5 and m["recall"] == pytest.approx(1 / 3)


def test_rally_boundary_matching() -> None:
    truth = [(1.0, 9.0), (15.0, 22.0), (30.0, 41.0)]
    predicted = [(1.4, 8.2), (15.5, 24.0), (29.2, 41.9)]
    assert rally_boundary_accuracy(predicted, truth) == pytest.approx(2 / 3)
    assert rally_boundary_accuracy([], truth) == 0.0
