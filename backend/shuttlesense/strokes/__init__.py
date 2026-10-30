"""Stroke classification into 6 classes (F6)."""

from shuttlesense.strokes.classify import run
from shuttlesense.strokes.labels import (
    SHUTTLESET_TO_CLASS,
    SHUTTLESET_ZH_TO_EN,
    english_type,
    map_label,
)

__all__ = ["SHUTTLESET_TO_CLASS", "SHUTTLESET_ZH_TO_EN", "english_type", "map_label", "run"]
