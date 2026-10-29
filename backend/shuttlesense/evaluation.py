"""Evaluation metrics shared by the eval scripts (T2.10, T3.7, T6.7, T7.2, T7.3).

Pure NumPy so they are unit-tested in CI; the scripts that run them need data and models.
"""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np


def match_events(
    predicted: Sequence[int], truth: Sequence[int], tolerance: int
) -> list[tuple[int, int]]:
    """Greedy one-to-one matching of event frames within +-tolerance, closest pairs first.

    Returns (predicted index, truth index) pairs.
    """
    pairs = sorted(
        (abs(p - t), i, j)
        for i, p in enumerate(predicted)
        for j, t in enumerate(truth)
        if abs(p - t) <= tolerance
    )
    used_p: set[int] = set()
    used_t: set[int] = set()
    matched = []
    for _d, i, j in pairs:
        if i not in used_p and j not in used_t:
            used_p.add(i)
            used_t.add(j)
            matched.append((i, j))
    return sorted(matched)


def _prf(tp: int, n_pred: int, n_true: int) -> dict[str, float]:
    precision = tp / n_pred if n_pred else 0.0
    recall = tp / n_true if n_true else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"precision": precision, "recall": recall, "f1": f1}


def hit_metrics(
    predicted: Sequence[tuple[int, str]],
    truth: Sequence[tuple[int, str]],
    tolerance: int = 3,
) -> dict[str, float]:
    """Hit detection P/R/F1 within +-tolerance frames, plus player-assignment accuracy on
    the matched hits. Items are (frame, player)."""
    matched = match_events([p[0] for p in predicted], [t[0] for t in truth], tolerance)
    result = _prf(len(matched), len(predicted), len(truth))
    same = sum(1 for i, j in matched if predicted[i][1] == truth[j][1])
    result["player_accuracy"] = same / len(matched) if matched else 0.0
    result["matched"] = len(matched)
    return result


def tracking_accuracy(
    pred_xy: np.ndarray,
    pred_visible: np.ndarray,
    true_xy: np.ndarray,
    true_visible: np.ndarray,
    tolerance_px: float = 4.0,
) -> dict[str, float]:
    """Per-frame shuttle detection accuracy (TrackNet convention).

    A frame is correct when both say invisible, or both say visible and the positions are
    within tolerance_px. Also returns precision/recall of visible detections.
    """
    pv = np.asarray(pred_visible) > 0
    tv = np.asarray(true_visible) > 0
    dist = np.linalg.norm(np.asarray(pred_xy, float) - np.asarray(true_xy, float), axis=1)
    close = pv & tv & (dist <= tolerance_px)
    correct = close | (~pv & ~tv)
    n = len(tv)
    result = _prf(int(close.sum()), int(pv.sum()), int(tv.sum()))
    result["accuracy"] = float(correct.sum() / n) if n else 0.0
    return result


def rally_boundary_accuracy(
    predicted: Sequence[tuple[float, float]],
    truth: Sequence[tuple[float, float]],
    tolerance_s: float = 1.0,
) -> float:
    """Share of true rallies (start_s, end_s) matched by a predicted rally whose start and
    end are both within tolerance_s (each prediction used once)."""
    used: set[int] = set()
    hits = 0
    for ts, te in truth:
        for i, (ps, pe) in enumerate(predicted):
            if i not in used and abs(ps - ts) <= tolerance_s and abs(pe - te) <= tolerance_s:
                used.add(i)
                hits += 1
                break
    return hits / len(truth) if truth else 0.0
