"""ShuttleSet stroke type -> ShuttleSense 6-class mapping (task T3.3).

The ShuttleSet CSVs name stroke types in Chinese: 18 types plus 未知球種 ("unknown"). The English
names follow the ShuttleSet paper (Wang et al., KDD 2023). Keep both tables identical to the one
in docs/DATA_FORMAT.md.
"""

from __future__ import annotations

from shuttlesense.schema import StrokeClass

# English ShuttleSet type names (lowercase). None = excluded from training.
SHUTTLESET_TO_CLASS: dict[str, StrokeClass | None] = {
    "smash": "smash",
    "wrist smash": "smash",
    "clear": "clear",
    "drop": "drop",
    "passive drop": "drop",
    "net shot": "net_shot",
    "return net": "net_shot",
    "cross-court net shot": "net_shot",
    "rush": "net_shot",
    "lob": "lift",
    "defensive return lob": "lift",
    "push": "lift",
    "short service": "serve",
    "long service": "serve",
    "drive": None,
    "driven flight": None,
    "back-court drive": None,
    "defensive return drive": None,
    "unknown": None,
}

# The `type` column of the ShuttleSet annotation CSVs -> English name above.
SHUTTLESET_ZH_TO_EN: dict[str, str] = {
    "殺球": "smash",
    "點扣": "wrist smash",
    "長球": "clear",
    "切球": "drop",
    "過度切球": "passive drop",
    "放小球": "net shot",
    "擋小球": "return net",
    "勾球": "cross-court net shot",
    "撲球": "rush",
    "挑球": "lob",
    "防守回挑": "defensive return lob",
    "推球": "push",
    "發短球": "short service",
    "發長球": "long service",
    "平球": "drive",
    "小平球": "driven flight",
    "後場抽平球": "back-court drive",
    "防守回抽": "defensive return drive",
    "未知球種": "unknown",
}


def english_type(shuttleset_type: str) -> str:
    """English, lowercase name of a ShuttleSet type given in Chinese or English."""
    name = shuttleset_type.strip()
    return SHUTTLESET_ZH_TO_EN.get(name, name.lower())


def map_label(shuttleset_type: str) -> StrokeClass | None:
    """Return the 6-class label, or None if the type is excluded. Raises KeyError if unknown.

    Accepts the Chinese names found in the ShuttleSet CSVs and their English translations."""
    return SHUTTLESET_TO_CLASS[english_type(shuttleset_type)]
