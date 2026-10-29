"""ShuttleSet 18-type -> ShuttleSense 6-class mapping (draft, finalized in T3.3).

Keep this table identical to the one in docs/DATA_FORMAT.md.
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
}


def map_label(shuttleset_type: str) -> StrokeClass | None:
    """Return the 6-class label, or None if the type is excluded. Raises KeyError if unknown."""
    return SHUTTLESET_TO_CLASS[shuttleset_type.strip().lower()]
