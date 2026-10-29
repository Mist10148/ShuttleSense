"""Classification metrics without scikit-learn (T3.8, T3.9, T7.3)."""

from __future__ import annotations

from collections.abc import Sequence

import numpy as np


def confusion_matrix(y_true: Sequence[int], y_pred: Sequence[int], num_classes: int) -> np.ndarray:
    """[true, predicted] counts."""
    cm = np.zeros((num_classes, num_classes), dtype=int)
    for t, p in zip(y_true, y_pred, strict=True):
        cm[int(t), int(p)] += 1
    return cm


def classification_report(
    y_true: Sequence[int], y_pred: Sequence[int], classes: Sequence[str]
) -> dict:
    """Accuracy, macro accuracy (mean per-class recall), macro F1 and per-class P/R/F1."""
    cm = confusion_matrix(y_true, y_pred, len(classes))
    tp = np.diag(cm).astype(float)
    support = cm.sum(axis=1).astype(float)
    predicted = cm.sum(axis=0).astype(float)
    with np.errstate(invalid="ignore", divide="ignore"):
        recall = np.where(support > 0, tp / support, 0.0)
        precision = np.where(predicted > 0, tp / predicted, 0.0)
        f1 = np.where(precision + recall > 0, 2 * precision * recall / (precision + recall), 0.0)
    present = support > 0
    total = cm.sum()
    per_class = {
        c: {
            "precision": float(precision[i]),
            "recall": float(recall[i]),
            "f1": float(f1[i]),
            "support": int(support[i]),
        }
        for i, c in enumerate(classes)
    }
    return {
        "accuracy": float(tp.sum() / total) if total else 0.0,
        "macro_accuracy": float(recall[present].mean()) if present.any() else 0.0,
        "macro_f1": float(f1[present].mean()) if present.any() else 0.0,
        "per_class": per_class,
        "confusion_matrix": cm.tolist(),
    }
